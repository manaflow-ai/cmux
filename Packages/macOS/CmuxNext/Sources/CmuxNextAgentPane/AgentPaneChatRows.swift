import AppKit
import CmuxNextAgentList
import CmuxNextWakeups
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The agent page's `cmux.agent.chat.rows.*` operations (the design doc's host contract), on a page
/// route of their own so ``AgentPageProvider`` never sees them: the chat's rows over the pane's
/// acpmux v2 client handle (``AcpmuxChatRowsHost``), each batch handed to the page in one call to
/// `window.cmuxChatRows.receive`. Nothing here parses a change; socket work and the call's script
/// are built off the main actor, and the page gets one call per batch.
///
/// - The handle opens at the document's first `chat.rows.open`, on the pane's own daemon on this
///   Mac (``AgentPaneModel/pendingAsksSocket``); no socket (a chat on another machine, a pane
///   before its handshake) or no client answers `chat.rows.off` and the page runs v1.
/// - `open` is refused for a chat that is not one of the pane's sessions with the v1 transport's
///   code for the same case, `transport.session_not_in_pane`, and no `sub` goes out.
/// - Hidden is ``AgentPaneFramePacer/nobodySees(_:)`` on the page view, the signal v1's pacer reads;
///   a ``AgentPaneVisibilityProbe`` on the page says when it changes, and each `taken` reads it again.
/// - Page gone is ``pageDidClose()``: the page router's close, at a new document, a crash or the
///   pane's close. The host ends the page's sids and lets its handle go.
@MainActor
final class AgentPaneChatRows: PageProvider {
    static let prefix = AgentPageOps.namespace + "chat.rows."

    /// The pane's own daemon socket on this Mac, or nil (tests replace it).
    var socket: @MainActor () -> String?
    /// Whether `chat` is one of the pane's sessions (tests replace it).
    var holdsSession: @MainActor (String) -> Bool
    /// Whether nobody can see the page (tests replace it).
    var isHidden: @MainActor () -> Bool = { true }
    /// Makes the host for a socket; tests give one on the driver's feed seam.
    var makeHost: @MainActor (String, @escaping @Sendable (String) -> Void) -> AcpmuxChatRowsHost = { path, deliver in
        AcpmuxChatRowsHost(socketPath: path, deliver: deliver)
    }
    /// Runs the page's call for a batch, on the main actor (tests record it).
    var evaluate: @MainActor (String) -> Void = { _ in }

    private(set) var host: AcpmuxChatRowsHost?
    private var probe: AgentPaneVisibilityProbe?
    private var hiddenSent: Bool?

    init(model: AgentPaneModel?) {
        socket = { [weak model] in model?.pendingAsksSocket }
        holdsSession = { [weak model] session in model?.transport.sessions.contains(session) ?? false }
    }

    /// Reads hidden from `page` and hands each batch to it.
    func watch(_ page: PageWebView) {
        isHidden = { [weak page] in page.map(AgentPaneFramePacer.nobodySees) ?? true }
        evaluate = { [weak page] script in page?.evaluate(script) }
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        probe.onChange = { [weak self] in self?.refreshHidden() }
        // Set first: AppKit may call the probe back inside addSubview.
        self.probe = probe
        page.addSubview(probe)
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op.hasPrefix(Self.prefix), let body = params.foundationObject as? [String: Any] else { throw PageError.invalidParams(op) }
        let name = String(op.dropFirst(Self.prefix.count))
        if name == "taken" {
            guard let batch = (body["batch"] as? NSNumber)?.intValue else { throw PageError.invalidParams(op) }
            refreshHidden()
            host?.taken(batch: batch)
            return .null
        }
        guard let sid = body["sid"] as? String, let request = try? JSONSerialization.data(withJSONObject: body) else {
            throw PageError.invalidParams(op)
        }
        switch name {
        case "open":
            guard let chat = body["chat"] as? String else { throw PageError.invalidParams(op) }
            guard holdsSession(chat) else {
                throw PageError(code: AgentPaneTransportError.sessionNotInPane.rawValue, message: "This chat is not one of the pane's")
            }
            guard let host = openHost() else { throw Self.refusal(.off) }
            let opened = try await Self.value(host.open(sid: sid, request: request))
            return .object(["sid": .string(opened)])
        case "close":
            guard let host else { throw Self.refusal(.name) }
            try await Self.value(host.close(sid: sid))
            return .null
        case "page":
            guard let host else { throw Self.refusal(.name) }
            try await Self.value(host.page(sid: sid, request: request))
            return .null
        case "blob":
            guard let id = body["id"] as? String else { throw PageError.invalidParams(op) }
            guard let host else { throw Self.refusal(.name) }
            let asked = try await Self.value(host.blob(sid: sid, id: id, request: request))
            return .object(["id": .string(asked)])
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The page is gone: its sids end, the connection closes, the handle goes.
    func pageDidClose() {
        host?.pageGone()
        host = nil
        hiddenSent = nil
    }

    private func openHost() -> AcpmuxChatRowsHost? {
        if let host { return host }
        guard let path = socket(), !path.isEmpty else { return nil }
        let host = makeHost(path) { [weak self] script in
            // The host calls from its own queue, once a batch: one main-queue turn runs the page's one call.
            MainDelivery().run { self?.evaluate(script) }
        }
        self.host = host
        refreshHidden()
        return host
    }

    private func refreshHidden() {
        guard let host else { return }
        let hidden = isHidden()
        guard hiddenSent != hidden else { return }
        hiddenSent = hidden
        host.setHidden(hidden)
    }

    private static func refusal(_ refusal: AcpmuxChatRowsHost.Refusal) -> PageError {
        PageError(code: refusal.rawValue, message: "The chat's rows are not available")
    }

    @discardableResult
    private static func value<T>(_ result: Result<T, AcpmuxChatRowsHost.Refusal>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let refusal): throw Self.refusal(refusal)
        }
    }
}
