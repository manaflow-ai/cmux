import AppKit
import CmuxNextCompat
import Foundation

/// The agent pane on the right of a Home chat (user 2026-11-03, msg 19960): ``HomeAgentSidePane``'s tab
/// strip over the selected agent's ``HomeAgentChatView`` (with the composer the person shares with the Chief), kept on ``HomeAgentPane`` (the tabs, the selection)
/// and on each agent's chat in the store (a new report redraws its tab and, while it shows, is seen).
@MainActor
final class HomeAgentPaneView: NSView {
    /// The tabs and selection this view draws.
    let pane: HomeAgentPane
    /// Go to workspace: the host opens the Chief's link to the agent's session (its workspace tab).
    var onGoToWorkspace: ((URL) -> Void)?
    let side = HomeAgentSidePane()
    /// The last Go to workspace click's place read and open (tests await it).
    private(set) var pendingGo: Task<Void, Never>?
    /// What each open tab draws now.
    private var drawn: [String: HomeAgentChatContent?] = [:]
    // task-owner: this view; event-driven (Observation), cancelled by stop()
    private var watch: Task<Void, Never>?

    /// What the pane shows at one moment: the tabs, the selection and the selected agent's chat.
    private struct Shown: Equatable, Sendable {
        var tabs: [String]
        var selected: String?
        var content: HomeAgentChatContent?
    }

    /// - Parameter pane: The tabs and selection to draw.
    init(pane: HomeAgentPane) {
        self.pane = pane
        super.init(frame: .zero)
        side.frame = bounds
        side.autoresizingMask = [.width, .height]
        addSubview(side)
        side.onSelect = { [weak pane] in pane?.select($0) }
        side.onClose = { [weak pane] in pane?.close($0) }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Stops following the pane (the chat closed).
    func stop() {
        watch?.cancel()
        watch = nil
    }

    private func follow() {
        let pane = pane
        watch = Task { [weak self] in
            let states = ObservationStream {
                Shown(tabs: pane.tabs, selected: pane.selected, content: pane.selected.flatMap { pane.content($0, now: Date()) })
            }
            for await shown in states {
                guard let self else { return }
                apply(shown)
            }
        }
    }

    /// Draws `shown` now (also the tests' way in, with no wait for the observation).
    func apply() {
        apply(Shown(tabs: pane.tabs, selected: pane.selected, content: pane.selected.flatMap { pane.content($0, now: Date()) }))
    }

    private func apply(_ shown: Shown) {
        for peer in side.peers where !shown.tabs.contains(peer) {
            side.close(peer)
            drawn[peer] = nil
        }
        for peer in shown.tabs where !side.peers.contains(peer) {
            let content = peer == shown.selected ? shown.content : pane.content(peer, now: Date())
            side.open(peer, title: content?.title ?? peer) { chat(content, peer: peer) }
            drawn[peer] = .some(content)
        }
        guard let selected = shown.selected else { return }
        if drawn[selected] != .some(shown.content) {
            drawn[selected] = .some(shown.content)
            let title = shown.content?.title ?? selected
            // The open chat redraws in place, so the composer keeps what the person types.
            if let content = shown.content, let open = side.content(of: selected) as? HomeAgentChatView {
                open.update(content)
                side.retitle(selected, title: title)
            } else {
                side.replace(selected, title: title, content: chat(shown.content, peer: selected))
            }
            pane.selectedChanged()
            // task-owner: one place read for the open tabs; a move redraws through the store
            Task { [weak pane] in await pane?.followSessions() }
        }
        side.select(selected)
    }

    /// The chat view of `content` (an empty one for an agent whose chat is not loaded).
    private func chat(_ content: HomeAgentChatContent?, peer: String) -> NSView {
        let content = content ?? HomeAgentChatContent(peer: peer, title: peer, status: "", task: "", workedFor: "", details: [],
                                                      messages: [], workspaceLink: nil)
        // Go to workspace reads where the agent runs at that moment, so it opens the place it moved to.
        let go: (() -> Void)? = content.workspaceLink.map { _ in
            { [weak self, weak pane] in
                guard let self else { return }
                // task-owner: one place read, then one open; ends when the owner answers
                pendingGo = Task { @MainActor [weak self] in
                    guard let url = await pane?.goToWorkspace(peer) else { return }
                    self?.onGoToWorkspace?(url)
                }
            }
        }
        let sent: (String) -> Void = { [weak pane] text in pane?.send(text, to: peer) }
        return HomeAgentChatView(content: content, actions: HomeAgentChatView.Actions(goToWorkspace: go, sent: sent))
    }

    /// The selected tab's chat view (tests).
    var selectedChat: HomeAgentChatView? { side.selectedContent as? HomeAgentChatView }
}
