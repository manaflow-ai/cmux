import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Main-window support types and persisted-geometry keys
extension AppDelegate {
    @MainActor
    final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        var fileExplorerState: FileExplorerState?
        let keyboardFocusCoordinator: MainWindowFocusController
        var cmuxConfigStore: CmuxConfigStore?
        weak var window: NSWindow?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            fileExplorerState: FileExplorerState?,
            cmuxConfigStore: CmuxConfigStore?,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.fileExplorerState = fileExplorerState
            self.cmuxConfigStore = cmuxConfigStore
            self.window = window
            self.keyboardFocusCoordinator = MainWindowFocusController(
                windowId: windowId,
                window: window,
                tabManager: tabManager,
                fileExplorerState: fileExplorerState
            )
        }
    }

    @MainActor
    final class NewWorkspaceContextMenuActionBox: NSObject {
        let windowId: UUID
        let action: CmuxResolvedConfigAction

        init(windowId: UUID, action: CmuxResolvedConfigAction) {
            self.windowId = windowId
            self.action = action
        }
    }

    final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?
        var shouldClose: (() -> Bool)?

        #if DEBUG
        private func logWindowEvent(_ event: String, notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            let id = window.identifier?.rawValue ?? "<nil>"
            cmuxDebugLog(
                "mainWindow.delegate.\(event) window=\(id) visible=\(window.isVisible ? 1 : 0) mini=\(window.isMiniaturized ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
            )
        }
        #endif

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }

        #if DEBUG
        func windowDidDeminiaturize(_ notification: Notification) {
            logWindowEvent("didDeminiaturize", notification: notification)
        }

        func windowDidMiniaturize(_ notification: Notification) {
            logWindowEvent("didMiniaturize", notification: notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            logWindowEvent("didBecomeKey", notification: notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            logWindowEvent("didResignKey", notification: notification)
        }

        func windowDidBecomeMain(_ notification: Notification) {
            logWindowEvent("didBecomeMain", notification: notification)
        }

        func windowDidResignMain(_ notification: Notification) {
            logWindowEvent("didResignMain", notification: notification)
        }
        #endif

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let shouldClose = shouldClose?() ?? true
            if shouldClose {
                WebViewInspectorTeardown.closeAllInspectors(in: sender)
            }
            return shouldClose
        }

        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
            guard window is CmuxMainWindow else { return newFrame }
            return CmuxMainWindow.standardFrame(forDefaultFrame: newFrame)
        }
    }

    struct ScriptableMainWindowState {
        let windowId: UUID
        let tabManager: TabManager
        let window: NSWindow?
    }

    struct SessionDisplayGeometry {
        let displayID: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct PersistedWindowGeometry: Codable, Sendable {
        let version: Int
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    nonisolated static let persistedWindowGeometrySchemaVersion = 2
    nonisolated static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v2"
#if DEBUG
    nonisolated static var debugPersistedWindowGeometryDefaultsKey: String { persistedWindowGeometryDefaultsKey }
#endif
    nonisolated static let legacyPersistedWindowGeometryDefaultsKeys = [
        "cmux.session.lastWindowGeometry.v1"
    ]

}
