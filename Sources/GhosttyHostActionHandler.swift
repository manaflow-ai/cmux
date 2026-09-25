import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

/// Adapts Ghostty intents to the existing cmux owners; it owns no workspace state.
@MainActor
struct GhosttyHostActionHandler {
    let app: AppDelegate
    let ghostty: GhosttyApp

    private struct Context {
        var manager: TabManager?
        var workspaceID: UUID?
        var window: NSWindow?
    }

    func perform(_ action: GhosttyHostAction, target: ghostty_target_s) -> Bool {
        if case .unsupported(let name) = action {
            action.reportUnsupported(name)
            return false
        }
        guard let context = context(for: target) else {
            action.reportUnavailable()
            return false
        }
        switch action {
        case .newWorkspace:
            return app.performNewWorkspaceAction(
                tabManager: context.manager, debugSource: "ghostty.new_tab"
            )
        case .selectWorkspace(let index):
            guard let manager = context.manager else { break }
            return selectWorkspace(index, in: manager)
        case .moveWorkspace(let amount):
            guard let manager = context.manager,
                  let workspaceID = context.workspaceID,
                  let index = manager.tabs.firstIndex(where: { $0.id == workspaceID }),
                  manager.tabs.count > 1 else { return false }
            // Reduce before adding, so even Int.min/Int.max offsets cannot overflow.
            let count = manager.tabs.count
            let destination = (index + amount % count + count) % count
            guard destination != index else { return false }
            let before = manager.tabs.map(\.id)
            guard manager.reorderWorkspace(tabId: workspaceID, toIndex: destination) else { return false }
            return manager.tabs.map(\.id) != before
        case .closeWorkspace:
            guard let manager = context.manager, let workspaceID = context.workspaceID else { break }
            // Accept the intent synchronously, but leave the C callback before
            // confirmation/teardown can free its source Ghostty surface.
            Task { @MainActor [weak manager] in
                _ = manager?.closeWorkspaceWithConfirmation(tabId: workspaceID)
            }
            return true
        case .newWindow:
            app.openNewMainWindow(preferredWindow: context.window)
            return true
        case .closeWindow:
            guard let window = context.window, let manager = context.manager else { break }
            Task { @MainActor [weak app, weak window, weak manager] in
                guard let app, let window, manager?.window === window,
                      manager?.isFinalizedForWindowClose == false else { return }
                _ = app.closeWindowWithConfirmation(window)
            }
            return true
        case .toggleFullScreen:
            guard let window = context.window else { break }
            window.toggleFullScreen(nil)
            return true
        case .commandPalette:
            guard let window = context.window else { break }
            app.requestCommandPaletteCommands(preferredWindow: window, source: "ghostty.command_palette")
            return true
        case .openConfig:
            ghostty.openConfigurationInTextEdit()
            return true
        case .quit:
            Task { @MainActor in NSApp.terminate(nil) }
            return true
        case .unsupported:
            return false
        }
        action.reportUnavailable()
        return false
    }

    private func selectWorkspace(_ index: Int, in manager: TabManager) -> Bool {
        switch index {
        case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue):
            guard manager.tabs.count > 1 else { return false }
            manager.selectNextTab()
        case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue):
            guard manager.tabs.count > 1 else { return false }
            manager.selectPreviousTab()
        case Int(GHOSTTY_GOTO_TAB_LAST.rawValue):
            guard !manager.tabs.isEmpty else { return false }
            manager.selectLastTab()
        default:
            guard index > 0, index <= manager.tabs.count else { return false }
            manager.selectTab(at: index - 1)
        }
        return true
    }

    private func context(for target: ghostty_target_s) -> Context? {
        if target.tag == GHOSTTY_TARGET_APP { return Context() }
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let runtime = target.target.surface,
              let callback = GhosttyApp.callbackContext(from: ghostty_surface_userdata(runtime)),
              let surface = callback.terminalSurface,
              surface.surface == runtime,
              GhosttyApp.terminalSurfaceRegistry.surface(id: callback.surfaceId) === surface,
              let ownerID = callback.tabId else { return nil }

        // Window-Dock terminals use the window ID as owner. Their workspace
        // commands target that window's selected workspace, never the active window.
        if let manager = app.tabManagerFor(tabId: ownerID),
           !manager.isFinalizedForWindowClose, manager.window != nil {
            return Context(manager: manager, workspaceID: ownerID, window: manager.window)
        }
        if let manager = app.tabManagerForWindowDockOwner(ownerID),
           !manager.isFinalizedForWindowClose, manager.window != nil {
            return Context(manager: manager, workspaceID: manager.selectedTabId, window: manager.window)
        }
        return nil
    }
}
