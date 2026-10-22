import AppKit
import CmuxCommandPalette
import Foundation

extension Notification.Name {
    /// Asks the main window (the notification's object) to open find-window.
    static let findTmuxWindowRequested = Notification.Name(CommandPaletteRequestKind.findTmuxWindow.notificationName)
}

extension AppDelegate {
    /// Opens find-window for its shortcut while any mirrored tmux pane exists.
    /// Returns whether the event was used.
    func routeFindTmuxWindowShortcut(event: NSEvent, targetWindow: NSWindow?) -> Bool {
        guard hasRemoteTmuxFindWindowCandidates,
              matchConfiguredShortcut(event: event, action: .findTmuxWindow) else { return false }
        requestRemoteTmuxFindWindow(preferredWindow: targetWindow, source: "shortcut.findTmuxWindow")
        return true
    }

    /// Opens find-window, the panel that searches every mirrored tmux pane.
    func requestRemoteTmuxFindWindow(preferredWindow: NSWindow? = nil, source: String = "api.findTmuxWindow") {
        postCommandPaletteRequest(
            kind: .findTmuxWindow,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    /// Whether any mirrored tmux pane exists for find-window to search.
    var hasRemoteTmuxFindWindowCandidates: Bool {
        remoteTmuxController.sessionMirrors.values.contains {
            !$0.connection.exited && $0.mirroredWorkspaceId != nil
        }
    }

    /// The find-window model for one opening of the panel.
    ///
    /// - Parameters:
    ///   - focusedWorkspaceId: searched first and listed first.
    ///   - didJump: called after a result was activated, so the panel can close.
    func makeRemoteTmuxFindWindowModel(
        focusedWorkspaceId: UUID?,
        didJump: @escaping @MainActor () -> Void
    ) -> RemoteTmuxFindWindowModel {
        RemoteTmuxFindWindowModel(environment: .init(
            candidates: { [weak self] in
                guard let self else { return [] }
                let order = self.mainWindowContexts.values
                    .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
                    .flatMap { $0.tabManager.tabs.map(\.id) }
                return self.remoteTmuxController.findWindowCandidates(
                    workspaceOrder: order,
                    focusedWorkspaceId: focusedWorkspaceId
                )
            },
            readText: { [weak self] candidate in
                await self?.remoteTmuxController.readFindWindowText(for: candidate)
            },
            jump: { [weak self] result in
                didJump()
                self?.jumpToRemoteTmuxFindWindowResult(result)
            }
        ))
    }

    /// Goes to a find-window result: selects its workspace and tab, focuses the
    /// pane, and for a content match opens the pane's find bar on the matched text
    /// so the surface scrolls to it. A match older than the attach seed reached
    /// loads the pane's full tmux history first.
    func jumpToRemoteTmuxFindWindowResult(_ result: RemoteTmuxFindWindowResult) {
        let candidate = result.candidate
        guard let context = mainWindowContexts.values.first(where: { context in
            context.tabManager.tabs.contains { $0.id == candidate.workspaceId }
        }), let workspace = context.tabManager.tabs.first(where: { $0.id == candidate.workspaceId }) else {
            NSSound.beep()
            return
        }
        _ = focusMainWindow(windowId: context.windowId)
        context.tabManager.selectTab(workspace)
        TerminalController.shared.setActiveTabManager(context.tabManager)
        guard let surfaceId = candidate.surfaceId else { return }
        context.tabManager.focusSurface(tabId: workspace.id, surfaceId: surfaceId)
        guard case let .content(hit) = result.match,
              !hit.matchedText.isEmpty,
              let panel = workspace.terminalPanel(for: surfaceId) else { return }
        let tabManager = context.tabManager
        Self.remoteTmuxFindWindowJumper.jump(
            loadsFullHistoryFirst: hit.isBeyondAttachSeed,
            reseed: { [weak self] in
                await self?.remoteTmuxController.reseedFullHistory(forSurfaceId: surfaceId) ?? .failed
            },
            isStillTarget: { [weak tabManager, weak workspace] in
                guard let tabManager, let workspace else { return false }
                return tabManager.selectedTabId == workspace.id && workspace.focusedSurfaceId == surfaceId
            },
            openSearch: { [weak panel] in
                guard let surface = panel?.surface else { return }
                _ = startOrFocusTerminalSearch(surface, initialNeedle: hit.matchedText)
            }
        )
    }

    /// One jump at a time across every window.
    private static let remoteTmuxFindWindowJumper = RemoteTmuxFindWindowJumper()
}
