import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation
import Observation

/// Non-view orchestration for `RightSidebarPanelView`, lifted off the view so the
/// SwiftUI body stays declarative. Owns the right sidebar's transient sub-state
/// (the three shortcut-hint modifier monitors, the dock controls store, and the
/// content-mount latch) and the imperative lifecycle helpers that drive it. The
/// view holds this via `@State`; reactive inputs (settings flags, the file
/// explorer/session stores, the active workspace) stay on the view and are passed
/// into each method at call time so behavior matches the previous inline reads
/// exactly. App-side: `AppDelegate.shared` focus routing and `NSApp` key-window
/// lookup remain here.
@MainActor
@Observable
final class RightSidebarPanelModel {
    let modeShortcutHintMonitor: WindowScopedShortcutHintModifierMonitor
    let focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    let closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    let dockStore = DockControlsStore()
    var hasMountedRightSidebarContent = false

    init() {
        modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
            guard let responder = window.firstResponder else { return false }
            return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
        }
    }

    func startShortcutHintMonitorsIfNeeded(showModifierHoldHints: Bool) {
        guard showModifierHoldHints else {
            stopShortcutHintMonitors()
            return
        }
        modeShortcutHintMonitor.start()
        focusShortcutHintMonitor.start()
        closeShortcutHintMonitor.start()
    }

    func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }

    func synchronizeDockLifecycle(
        isRightSidebarVisible: Bool,
        mode: RightSidebarMode,
        rootDirectory: String?,
        workspaceId: UUID?
    ) {
        dockStore.synchronizeSidebarLifecycle(
            isRightSidebarVisible: isRightSidebarVisible,
            mode: mode,
            rootDirectory: rootDirectory,
            workspaceId: workspaceId
        )
    }

    func selectMode(
        _ mode: RightSidebarMode,
        fileExplorerState: FileExplorerState,
        sessionIndexStore: SessionIndexStore
    ) {
        fileExplorerState.mode = mode
        if fileExplorerState.mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexStore.currentDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }

    func refreshModeAvailabilityAndFocusIfNeeded(
        fileExplorerState: FileExplorerState,
        dockRootDirectory: String?,
        workspaceId: UUID?
    ) {
        let previousMode = fileExplorerState.mode
        fileExplorerState.refreshModeAvailability()
        let mode = fileExplorerState.mode
        if previousMode == mode {
            synchronizeDockLifecycle(
                isRightSidebarVisible: fileExplorerState.isVisible,
                mode: mode,
                rootDirectory: dockRootDirectory,
                workspaceId: workspaceId
            )
        }
        guard previousMode != mode,
              fileExplorerState.isVisible,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else { return }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: fileExplorerState.mode,
            focusFirstItem: false,
            preferredWindow: window
        )
    }
}
