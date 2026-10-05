import Foundation
import os

/// One question the app puts to the user about a clipboard read.
public struct ClipboardReadPrompt: Sendable, Hashable {
    public var requestID: String
    public var terminalID: String
    public var location: TerminalClipboardRead.Location
    /// The host the sheet names (the app's own label for its connection).
    public var host: ClipboardReadHost
}

/// The app's half of the OSC 52 clipboard-read broker (layer 4 of decision
/// CLIPBOARD-READ-BROKER) for one daemon connection. It keeps the daemon's
/// subscription equal to the terminals the app shows (resent when that set
/// changes and after each reconnect, never on a timer), and answers each
/// `terminal-clipboard-read` from the user's Ghostty `clipboard-read`
/// setting: `allow` with the pasteboard text, `deny` with a refusal, `ask`
/// with one question per request (one open per terminal). A read for a
/// terminal it did not subscribe is ignored. Replies come only from here,
/// that is from the setting or the user's answer. Logs carry request ids,
/// never clipboard text.
@MainActor
public final class TerminalClipboardBroker {
    /// What the broker needs from the app and the connection.
    public struct Environment {
        /// The applied Ghostty `clipboard-read` setting, read per request.
        public var setting: @MainActor () -> ClipboardReadSetting
        /// The pasteboard text for a location; nil when it holds none.
        public var pasteboardText: @MainActor (TerminalClipboardRead.Location) -> String?
        /// Shows the question and calls the answer once (true grants).
        /// Returns the closer the broker calls when the read is cancelled;
        /// closing must not call the answer with true.
        public var ask: @MainActor (ClipboardReadPrompt, @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void
        /// Sends `terminal-clipboard-subscribe`.
        public var subscribe: @MainActor ([String]) async throws -> Void
        /// Sends `terminal-clipboard-reply` (nil text refuses).
        public var reply: @MainActor (String, String?) async throws -> Void

        public init(setting: @escaping @MainActor () -> ClipboardReadSetting,
                    pasteboardText: @escaping @MainActor (TerminalClipboardRead.Location) -> String?,
                    ask: @escaping @MainActor (ClipboardReadPrompt, @escaping @MainActor (Bool) -> Void) -> @MainActor () -> Void,
                    subscribe: @escaping @MainActor ([String]) async throws -> Void,
                    reply: @escaping @MainActor (String, String?) async throws -> Void) {
            self.setting = setting
            self.pasteboardText = pasteboardText
            self.ask = ask
            self.subscribe = subscribe
            self.reply = reply
        }
    }

    /// The daemon's per-connection terminal cap (commands.md).
    public static let maxTerminals = 256
    /// The daemon refuses longer reply text (UTF-8 bytes).
    public static let maxReplyBytes = 1 << 20

    private struct Pending {
        var terminalID: String
        var close: (@MainActor () -> Void)?
    }

    /// The host this connection reaches (this Mac for the local daemon).
    public let host: ClipboardReadHost
    private let environment: Environment
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.clipboard")
    /// The terminals the app shows, sorted and capped.
    private var desired: [String] = []
    /// The set the daemon acknowledged on this connection; nil before.
    private var acknowledged: [String]?
    /// The set being sent, while a subscribe is in flight.
    private var inFlight: [String]?
    /// The current connection, nil while disconnected. A new value is a new
    /// daemon connection: its subscription starts empty.
    private var connection: Int?
    private var pending: [String: Pending] = [:]
    /// The running subscribe (tests await it).
    private(set) var subscribing: Task<Void, Never>?
    /// The last queued reply; replies go out in order (tests await it).
    private(set) var lastReply: Task<Void, Never>?

    public init(host: ClipboardReadHost, environment: Environment) {
        self.host = host
        self.environment = environment
    }

    /// Request ids with an open question.
    public var openRequests: Set<String> { Set(pending.keys) }

    /// Terminals whose reads this broker answers: the acknowledged set and the
    /// one being sent (the daemon may route a read before its reply arrives).
    public var subscribedTerminals: Set<String> {
        Set(acknowledged ?? []).union(inFlight ?? [])
    }

    // MARK: Subscription

    /// The terminals the app shows on this connection. Sends a new
    /// subscription when the set changed.
    public func setTerminals(_ terminals: some Sequence<String>) {
        let sorted = Array(Set(terminals)).sorted()
        if sorted.count > Self.maxTerminals {
            logger.error("clipboard reads: \(sorted.count) terminals, subscribing the first \(Self.maxTerminals)")
        }
        desired = Array(sorted.prefix(Self.maxTerminals))
        pump()
    }

    /// The connection changed: `id` names the live connection, nil when it
    /// dropped. Open questions end (the daemon refuses their reads when the
    /// connection closes) and a new connection subscribes again.
    public func setConnection(_ id: Int?) {
        guard id != connection else { return }
        connection = id
        acknowledged = nil
        inFlight = nil
        subscribing?.cancel()
        subscribing = nil
        closeAll()
        pump()
    }

    /// Ends every question and stops subscribing.
    public func stop() {
        connection = nil
        acknowledged = nil
        inFlight = nil
        subscribing?.cancel()
        subscribing = nil
        closeAll()
    }

    private func pump() {
        guard let connection, subscribing == nil, desired != acknowledged else { return }
        // A first subscription with no terminals has nothing to say.
        if acknowledged == nil, desired.isEmpty { return }
        let terminals = desired
        inFlight = terminals
        let subscribe = environment.subscribe
        subscribing = Task { [weak self] in
            let ok: Bool
            do {
                try await subscribe(terminals)
                ok = true
            } catch {
                ok = false
            }
            self?.subscribed(terminals, ok: ok, connection: connection)
        }
    }

    private func subscribed(_ terminals: [String], ok: Bool, connection: Int) {
        guard connection == self.connection else { return }
        subscribing = nil
        inFlight = nil
        guard ok else {
            // The next change or reconnect tries again; nothing retries on a timer.
            logger.error("clipboard reads: terminal-clipboard-subscribe failed")
            return
        }
        acknowledged = terminals
        pump()
    }

    // MARK: Reads

    /// Routes `terminal-clipboard-read` and `terminal-clipboard-read-cancelled`;
    /// other events are ignored.
    public func handle(_ event: DaemonEvent) {
        switch event {
        case .terminalClipboardRead(let read): handleRead(read)
        case .terminalClipboardReadCancelled(let requestID): cancel(requestID)
        default: break
        }
    }

    private func handleRead(_ read: TerminalClipboardRead) {
        let id = read.requestID
        guard connection != nil, subscribedTerminals.contains(read.terminalID) else {
            logger.info("clipboard read \(id, privacy: .public) ignored: terminal not subscribed")
            return
        }
        guard pending[id] == nil else { return }
        if pending.values.contains(where: { $0.terminalID == read.terminalID }) {
            // One open question per terminal (the daemon refuses these already).
            send(id, text: nil)
            return
        }
        let shown = shownHost(read.host)
        switch ClipboardReadPolicy.decide(environment.setting(), host: shown.kind) {
        case .allow:
            logger.info("clipboard read \(id, privacy: .public) allowed by clipboard-read")
            send(id, text: environment.pasteboardText(read.location))
        case .deny:
            logger.info("clipboard read \(id, privacy: .public) denied by clipboard-read")
            send(id, text: nil)
        case .ask:
            pending[id] = Pending(terminalID: read.terminalID)
            let prompt = ClipboardReadPrompt(requestID: id, terminalID: read.terminalID, location: read.location, host: shown)
            let location = read.location
            let close = environment.ask(prompt) { [weak self] granted in
                self?.answer(id, granted: granted, location: location)
            }
            // The question may have been answered while it opened.
            if pending[id] != nil { pending[id]?.close = close }
        }
    }

    /// The host the question names. The daemon reports its own terminals as
    /// local; through a remote or Cloud connection that host is the
    /// connection's, never this Mac.
    private func shownHost(_ reported: ClipboardReadHost) -> ClipboardReadHost {
        if host.kind != .local { return host }
        return reported.kind == .local ? host : reported
    }

    private func answer(_ id: String, granted: Bool, location: TerminalClipboardRead.Location) {
        guard pending.removeValue(forKey: id) != nil else { return }
        logger.info("clipboard read \(id, privacy: .public) \(granted ? "granted" : "refused", privacy: .public) by the user")
        send(id, text: granted ? environment.pasteboardText(location) : nil)
    }

    private func cancel(_ id: String) {
        guard let open = pending.removeValue(forKey: id) else { return }
        logger.info("clipboard read \(id, privacy: .public) cancelled by the daemon")
        open.close?()
    }

    private func closeAll() {
        let open = pending.values
        pending.removeAll()
        for entry in open { entry.close?() }
    }

    /// Queues one reply after the previous one. Text over the daemon's cap
    /// is refused here instead of being sent.
    private func send(_ id: String, text: String?) {
        let text = text.flatMap { $0.utf8.count <= Self.maxReplyBytes ? $0 : nil }
        let previous = lastReply
        let reply = environment.reply
        let logger = logger
        lastReply = Task {
            await previous?.value
            do {
                try await reply(id, text)
            } catch {
                logger.error("clipboard read \(id, privacy: .public): reply failed")
            }
        }
    }
}
