import AppKit

/// Tells acpmux once per edge whether anybody can see the pane's chat (`_acpmux/visibility`), so
/// acpmux can freeze the idle harness of a chat nobody sees (p14-energy-117). Chrome does the same
/// for a hidden tab: `RenderWidgetHostImpl::WasHidden` / `WasShown`
/// (content/browser/renderer_host/render_widget_host_impl.cc) send one one-way message per edge,
/// guarded by `is_hidden_`, and the freezing policy acts on the hidden page
/// (components/performance_manager/freezing/freezing_policy.cc).
///
/// - An edge (``changed()``) only marks the pane; the report runs on the next turn, so the hide or
///   show that caused it never pays for socket work, and edges in one turn make one report.
/// - The report compares the pane's state with the last one told for the same connection and
///   session: hide, hide, show sends two messages. acpmux counts a session it was never told
///   about as shown, so a new connection or session sends only a hide.
/// - Nothing waits: the send hands the frame to the socket and returns.
@MainActor final class AgentPaneVisibilityEdges {
    /// The connection and the session a report is about.
    struct Target: Equatable {
        var connection: Int
        var session: String
    }

    private let isHidden: @MainActor () -> Bool
    private let target: @MainActor () -> Target?
    private let send: @MainActor (_ target: Target, _ visible: Bool) -> Bool
    private let nextTurn: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private var scheduled = false
    /// The target acpmux was last told is hidden; nil: shown, or never told.
    private var toldHidden: Target?

    /// - Parameters:
    ///   - isHidden: Whether nobody can see the pane.
    ///   - target: The open connection (its first frame sent) and the chat it shows; nil sends nothing.
    ///   - send: Hands one report to the socket; false when the socket refused it.
    ///   - nextTurn: Runs the report after the turn of the edge.
    init(isHidden: @escaping @MainActor () -> Bool, target: @escaping @MainActor () -> Target?,
         send: @escaping @MainActor (_ target: Target, _ visible: Bool) -> Bool,
         nextTurn: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
             // task-owner: one report per turn with an edge; it runs once, on the main actor
             Task { @MainActor in work() }
         }) {
        self.isHidden = isHidden
        self.target = target
        self.send = send
        self.nextTurn = nextTurn
    }

    /// The pane may have been hidden or shown.
    func changed() {
        guard !scheduled else { return }
        scheduled = true
        nextTurn { [weak self] in self?.report() }
    }

    private func report() {
        scheduled = false
        guard let target = target() else { return }
        let hidden = isHidden()
        guard hidden != (toldHidden == target) else { return }
        guard send(target, !hidden) else { return }
        toldHidden = hidden ? target : nil
    }
}

extension AgentPaneVisibilityEdges {
    /// The edges of `view`'s chat, on the local acpmux only (a chat on another machine is that
    /// machine's to freeze). Its own ``AgentPaneVisibilityProbe`` keeps it: the pane holds no
    /// reference, and a closed pane's report finds no connection.
    static func install(on view: AgentPaneView) {
        let edges = AgentPaneVisibilityEdges(
            isHidden: { [weak view] in view.map { AgentPaneFramePacer.nobodySees($0) } ?? true },
            target: { [weak view] in
                guard let view, let session = view.model.sessionId else { return nil }
                let transport = view.model.transport
                guard transport.socket != nil, transport.sentFirst, !transport.remoteWire else { return nil }
                return Target(connection: transport.current, session: session)
            },
            send: { [weak view] target, visible in
                guard let transport = view?.model.transport, transport.current == target.connection,
                      let socket = transport.socket else { return false }
                return socket.sendVisibility(session: target.session, visible: visible) == nil
            })
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        probe.onChange = { edges.changed() }
        view.addSubview(probe)
    }
}
