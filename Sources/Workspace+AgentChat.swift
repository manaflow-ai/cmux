import AppKit

extension Workspace {
    func performSurfaceTabBarNewAgentChatAction(presentingWindow: NSWindow?) {
        guard let owningTabManager else { return }
        _ = AppDelegate.shared?.executeConfiguredCmuxAction(
            id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
            tabManager: owningTabManager,
            preferredWindow: presentingWindow
        )
    }

    /// Opens an agent chat as a tab in `pane`: the pane tab bar's "+" and its
    /// Agent Chat row. The Agent Chat command and its shortcut keep opening
    /// a new workspace.
    func openAgentChatTab(inPane pane: PaneID, presentingWindow: NSWindow?) {
        guard let owningTabManager, let appDelegate = AppDelegate.shared else {
            NSSound.beep()
            return
        }
        Task { @MainActor [weak self, weak owningTabManager] in
            guard let owningTabManager,
                  let url = await appDelegate.agentChatBrowserBaseURL(
                      tabManager: owningTabManager,
                      preferredWindow: presentingWindow
                  ),
                  let self,
                  self.bonsplitController.allPaneIds.contains(pane),
                  self.newBrowserSurface(inPane: pane, url: url, focus: true) != nil else {
                NSSound.beep()
                return
            }
        }
    }

    /// Opens a read-only chat view of the agent running in a terminal panel.
    /// The agent-chat sidecar renders the agent's own transcript, so the
    /// terminal process stays the only agent.
    func openTerminalChatView(terminalPanelId: UUID, presentingWindow: NSWindow?) {
        guard let owningTabManager, let appDelegate = AppDelegate.shared else {
            NSSound.beep()
            return
        }
        Task { @MainActor [weak self, weak owningTabManager] in
            guard let owningTabManager,
                  let base = await appDelegate.agentChatBrowserBaseURL(
                      tabManager: owningTabManager,
                      preferredWindow: presentingWindow
                  ),
                  let self,
                  let url = Self.terminalChatViewURL(base: base, terminalPanelId: terminalPanelId),
                  self.newBrowserSplit(
                      from: terminalPanelId,
                      orientation: .horizontal,
                      url: url,
                      transparentBackground: true
                  ) != nil else {
                NSSound.beep()
                return
            }
        }
    }

    /// `<sidecar>/terminal/<panel id>?transparent=1`; the sidecar maps the
    /// panel to its agent session through the hook session stores.
    static func terminalChatViewURL(base: URL, terminalPanelId: UUID) -> URL? {
        let path = base
            .appendingPathComponent("terminal", isDirectory: true)
            .appendingPathComponent(terminalPanelId.uuidString)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "transparent", value: "1")]
        return components?.url
    }
}
