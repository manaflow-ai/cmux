import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The app's native UI ops for React pages (plans/cmux-next/react-pages.md 1.3):
/// `cmux.app.action.run` runs one of the page's allowed registry actions with origin `page` (never
/// `user` unless a native sheet confirmed it, so rules such as destructive confirmation still
/// ask), and `cmux.app.clipboard.write` writes the pasteboard, only on the person's own gesture.
@MainActor
final class AppPageNativeProvider: PageProvider {
    private unowned let services: AppServices
    private let page: PageDescriptor
    /// Runs a confirmed namespace op on the provider that owns its namespace.
    var forward: (@MainActor (_ op: String, _ params: CmuxNextSettings.JSONValue, _ context: PageCallContext) async throws -> CmuxNextSettings.JSONValue)?
    var presenter: any PageConfirmationPresenter = DialogPageConfirmationPresenter()
    /// The page view the sheet attaches to.
    var anchor: () -> NSView? = { nil }
    /// Writes the text `cmux.app.clipboard.write` puts on the clipboard: the general
    /// pasteboard. Tests record it instead, so they run without a pasteboard server
    /// (a headless CI session has none, and a private NSPasteboard reads back nil there).
    var writeClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    init(services: AppServices, page: PageDescriptor) {
        self.services = services
        self.page = page
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case PageNativeOp.actionRun:
            if let name = params["action"]?.stringValue, let kind = page.confirmedOps[name] {
                return try await runConfirmed(name, kind: kind, args: params["args"] ?? .object([:]), context: context)
            }
            if params["action"]?.stringValue == BrowserTabOpen.action {
                return try await BrowserTabOpen.run(args: params["args"] ?? .object([:]), page: context.page, services: services)
            }
            guard let name = params["action"]?.stringValue, page.actions.contains(name) else {
                throw PageError(code: "cmux.app.action_refused", message: "\(params["action"]?.stringValue ?? "") is not an action of this page")
            }
            let id = ActionID(rawValue: name)
            // A person-only action (the import window, the CSV file picker) needs the person's own
            // click or key in this page view: page script alone never starts one.
            if services.registry.descriptor(for: id)?.isPersonOnly == true, !context.userGesture {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            // `target` is the CLI form `kind:id` (a browser profile row: `browser-profile:<id>`).
            var target: ActionTargetRef?
            if let text = params["target"]?.stringValue {
                guard let parsed = ActionTargetRef(parsing: text) else { throw PageError.invalidParams("target must be kind:id") }
                target = parsed
            }
            // A page control is not the user's own gesture (origin `page`): rules that need the user
            // (destructive confirmation) still ask. The click may change the view it was made in.
            let invocation = ActionInvocation(target: target, arguments: Self.arguments(params["args"], for: services.registry.descriptor(for: id)),
                                              origin: context.isConfirmedUser ? .user : .page, focusRequested: true)
            return ["ran": .bool(services.registry.perform(id, invocation: invocation))]
        case PageNativeOp.clipboardWrite:
            guard let text = params["text"]?.stringValue else { throw PageError.invalidParams("text is required") }
            // Only right after the person's own key, click or native menu choice in this page view
            // (tracked by the host, never by page script), or a native sheet they approved: page
            // script alone never replaces the clipboard.
            guard context.userGesture || context.isConfirmedUser else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            writeClipboard(text)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// A confirmed op (``PageDescriptor/confirmedOps``): the native sheet, then the op as the user's
    /// own on the namespace's provider. A declined sheet answers `{confirmed: false}` (the Cloud
    /// page's contract), an approved one `{confirmed: true, value}`.
    private func runConfirmed(_ op: String, kind: PageConfirmation.Kind, args: CmuxNextSettings.JSONValue,
                              context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard let forward else { throw PageError.unknownOp(op) }
        let labels = (args.objectValue ?? [:]).compactMapValues(\.stringValue)
        guard await presenter.confirm(.forOp(op, kind: kind, args: labels), anchor: anchor()) else { return ["confirmed": false] }
        let value = try await forward(op, args, PageCallContext(page: context.page, origin: "user", confirmed: true, opid: context.opid))
        return ["confirmed": true, "value": value]
    }

    /// The page's `args` object as typed action arguments, by the descriptor's schema.
    static func arguments(_ args: CmuxNextSettings.JSONValue?, for descriptor: ActionDescriptor?) -> [String: ActionValue] {
        guard case .object(let members)? = args else { return [:] }
        var out: [String: ActionValue] = [:]
        for (name, value) in members {
            let kind = descriptor?.arguments.first { $0.name == name }?.kind
            switch (kind, value) {
            case (.bool?, .bool(let flag)): out[name] = .bool(flag)
            case (.int?, .number(let number)): out[name] = .int(Int(number))
            case (_, .string(let text)): out[name] = .string(text)
            case (_, .bool(let flag)): out[name] = .bool(flag)
            case (_, .number(let number)): out[name] = .int(Int(number))
            default: continue
            }
        }
        return out
    }
}

/// Relays a page's namespace to the local daemon (react-pages.md 1.1): `cmux.<ns>.<verb>` is the
/// daemon's v2 op `<ns>.<verb>` (decision ONE-CATALOG: the short wire name is the canonical name's
/// alias). `idempotency_key` moves from params to the v2 envelope; the daemon's refusal codes come
/// back under `cmux.`. Until the pane-protocol router is in the daemon, this relay is the data path.
///
/// While the page is frozen its streams' listeners are paused (``PageRelayStreams``); the relay
/// channel then closes its daemon connection when idle (``PageRelayIdleClose``).
@MainActor
final class DaemonPageRelay: PageProvider {
    /// The process root's local daemon service (AppServices.machines.local), as `services` was before.
    private unowned let daemon: any PageRelayDaemon
    /// The page host's channels, shared by every page of the host.
    let channels: PageRelayChannels
    private let work: BackgroundWork
    private let eventWake: () -> FrameOutboxWake
    private let idleDeadline: () -> any PageRelayIdleDeadline
    private let streams = PageRelayStreams()

    /// The app's relay: the local daemon, the page host's channels, events on the app's frames,
    /// idle closes on the app's deadlines.
    convenience init(services: AppServices) {
        let deadlines = services.mainDeadlines, mainWork = services.mainWork
        self.init(daemon: services.machines.local, channels: services.webUI.relayChannels, work: services.work,
                  eventWake: { FrameOutboxWake.nextFrame(owner: "PageRelayChannel.events", on: mainWork) }) {
            // A close tears down what nobody uses: background class, behind input and visible work.
            MainDeadline(owner: "PageRelayChannel.idleClose", workClass: .background, scheduler: deadlines)
        }
    }

    /// - Parameters:
    ///   - daemon: The daemon the pages call (the local one in the app).
    ///   - channels: The page host's relay channels.
    ///   - work: Where a channel reads its events and its idle close closes its connection.
    ///   - eventWake: Makes a new channel's frame wake for the events it read off main.
    ///   - idleDeadline: Makes a new channel's idle close deadline.
    init(daemon: any PageRelayDaemon, channels: PageRelayChannels, work: BackgroundWork,
         eventWake: @escaping () -> FrameOutboxWake, idleDeadline: @escaping () -> any PageRelayIdleDeadline) {
        self.daemon = daemon
        self.channels = channels
        self.work = work
        self.eventWake = eventWake
        self.idleDeadline = idleDeadline
    }

    /// The relay channel of `page` on the daemon, kept by the page host.
    private func channel(for page: String) -> PageRelayChannel {
        PageRelayChannel.of(page: page, daemon: daemon, in: channels, work: work, events: eventWake, idle: idleDeadline)
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        guard op.hasPrefix("cmux.") else { throw PageError.unknownOp(op) }
        guard daemon.connection != nil else {
            throw PageError.closed
        }
        var members = params.objectValue ?? [:]
        let key = Self.idempotencyKey(members.removeValue(forKey: "idempotency_key")?.stringValue, context: context)
        do {
            // The page relay connection: origin `page`, or the user with a native-sheet token.
            let result = try await channel(for: context.page).send(
                operation: String(op.dropFirst("cmux.".count)), params: try Self.daemonParams(members), idempotencyKey: key,
                context: context, on: daemon)
            return try Self.pageValue(result)
        } catch let error as DaemonError {
            throw Self.pageError(error)
        }
    }

    /// A page stream `cmux.<ns>.<event>` is the daemon subscribe event `<ns>-<event>`
    /// (`cmux.history.changed` -> `history-changed`), as the daemon sent it, on the page's relay
    /// connection (page-events-v1, cx-hnmbt.9). The daemon decides which events a page hears; a
    /// stream it does not name is `unknown_op` (the page then reads without live updates). The
    /// channel reads each event off main and hands the page its members as they arrived, a frame's
    /// worth at a time (p05-ipc-109).
    func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        guard stream.hasPrefix("cmux.") else { throw PageError.unknownOp(stream) }
        guard daemon.connection != nil else { throw PageError.closed }
        let event = stream.dropFirst("cmux.".count).replacingOccurrences(of: ".", with: "-")
        do {
            let channel = self.channel(for: context.page)
            let listener = try await channel.listen(event: event, on: daemon, onEvent: onEvent)
            let stop = streams.add(listener: listener, on: channel.listeners) { onEvent(["resync": true]) }
            return Self.subscription(onCancel: stop)
        } catch is PageRelayChannel.NoSuchEvent {
            throw PageError.unknownOp(stream)
        } catch let error as DaemonError {
            throw Self.pageError(error)
        }
    }

    /// Frozen: no stream keeps a daemon listen. Thawed: each listens again and resyncs once.
    func pageWillFreeze() { streams.freeze() }
    func pageDidThaw() { streams.thaw() }

    /// Daemon page events are change notices the page answers with a fresh read (the relay sends
    /// `{resync: true}` after an overflow), so a frozen page keeps only the newest and a gap mark
    /// when older ones dropped. Never `.latest`: that would hide the lost changes.
    static func subscription(onCancel: @escaping () -> Void) -> PageSubscription {
        PageSubscription(frozenDelivery: .resync, onCancel: onCancel)
    }

    /// The v2 idempotency key: the page's own, else its operation id (decision 31), so a resend
    /// after a reconnect replays the daemon's first answer instead of applying twice.
    static func idempotencyKey(_ explicit: String?, context: PageCallContext) -> String? {
        explicit ?? context.opid
    }

    static func daemonParams(_ members: [String: CmuxNextSettings.JSONValue]) throws -> [String: CmuxNextDaemon.JSONValue] {
        try JSONDecoder().blockingDecode([String: CmuxNextDaemon.JSONValue].self,
                                 from: Data(CmuxNextSettings.JSONValue.object(members).compactText.utf8))
    }

    static func pageValue(_ value: CmuxNextDaemon.JSONValue) throws -> CmuxNextSettings.JSONValue {
        try CmuxNextSettings.JSONValue.parse(JSONEncoder().encode(value))
    }

    static func pageError(_ error: DaemonError) -> PageError {
        switch error {
        case .command(_, let message, let code, let details, let retryable):
            let pageCode = code.map { $0.hasPrefix("cmux.") ? $0 : "cmux." + $0 } ?? "cmux.daemon.failed"
            return PageError(code: pageCode, message: message, retryable: retryable ?? false,
                             details: details.flatMap { try? pageValue($0) })
        case .notConnected, .connectionClosed, .daemonShutdown:
            return PageError(code: "cmux.protocol.closed", message: error.description, retryable: true)
        case .timedOut:
            return PageError(code: "cmux.protocol.timeout", message: error.description, retryable: true)
        default:
            return PageError(code: "cmux.daemon.failed", message: error.description)
        }
    }
}

/// A namespace an organization policy can turn off (DisabledFeatures): while `turnedOff` answers a
/// reason, every call and stream is refused with it (`cmux.policy.turned_off`), so a page that was
/// open before the policy arrived stops too.
@MainActor
final class PolicyGatedPageProvider: PageProvider {
    private let inner: any PageProvider
    private let turnedOff: @MainActor () -> String?

    init(inner: any PageProvider, turnedOff: @escaping @MainActor () -> String?) {
        self.inner = inner
        self.turnedOff = turnedOff
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        if let reason = turnedOff() { throw PageError(code: "cmux.policy.turned_off", message: reason) }
        return try await inner.call(op, params: params, context: context)
    }

    /// Frozen delivery: the wrapped provider's own policy, unchanged (the gate refuses or forwards a
    /// stream, never changes what it keeps while the page is frozen).
    func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        if let reason = turnedOff() { throw PageError(code: "cmux.policy.turned_off", message: reason) }
        return try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }

    /// The wrapped provider's streams stop and start with the page.
    func pageWillFreeze() { inner.pageWillFreeze() }
    func pageDidThaw() { inner.pageDidThaw() }
}
