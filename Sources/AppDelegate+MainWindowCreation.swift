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


// MARK: - Main window creation and positioning
extension AppDelegate {
    func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           }) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number_scan",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "event_context_not_found",
            event: event,
            chosenContext: nil
        )
        #endif
        return nil
    }

    private func positionNewMainWindow(_ window: NSWindow, relativeTo sourceWindow: NSWindow) {
        let sourceFrame = sourceWindow.frame
        let sourceScreen = sourceWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) })
        guard let visibleFrame = sourceScreen?.visibleFrame else {
            window.center()
            return
        }

        let cascadeOffset: CGFloat = 24
        let minimumWindowSize = NSSize(width: 460, height: 360)
        var frame = window.frame
        frame.origin = NSPoint(
            x: sourceFrame.minX + cascadeOffset,
            y: sourceFrame.maxY - cascadeOffset - frame.height
        )
        window.setFrame(
            Self.clampFrame(
                frame,
                within: visibleFrame,
                minWidth: minimumWindowSize.width,
                minHeight: minimumWindowSize.height
            ),
            display: false
        )
    }

    @discardableResult
    func createMainWindow(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil,
        shouldActivate: Bool = true,
        sourceWindow preferredSourceWindow: NSWindow? = nil,
        remapClosedPanelHistoryFromSessionSnapshot: Bool = true,
        restoredSessionSnapshotHandler: (([[UUID: UUID]], TabManager) -> Void)? = nil
    ) -> UUID {
        reserveInitialSocketPathIfNeeded()
        let windowId = UUID()
        let tabManager = TabManager(
            initialWorkspaceTitle: initialWorkspaceTitle,
            initialWorkingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: initialTerminalInput == nil
        )
        if let sessionWindowSnapshot {
            let restoredPanelIdsByWorkspaceIndex = tabManager.restoreSessionSnapshot(
                sessionWindowSnapshot.tabManager,
                remapClosedPanelHistory: remapClosedPanelHistoryFromSessionSnapshot
            )
            if let originalWindowId = sessionWindowSnapshot.windowId,
               originalWindowId != windowId {
                ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: originalWindowId, to: windowId)
                ClosedItemHistoryStore.shared.flushPendingSaves()
            }
            restoredSessionSnapshotHandler?(restoredPanelIdsByWorkspaceIndex, tabManager)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map { SessionPersistencePolicy.sanitizedSidebarWidth($0) }
            ?? SessionPersistencePolicy.defaultSidebarWidth
#if DEBUG
        let shouldStartWithHiddenSidebarForTerminalViewportUITest =
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] == "1"
#else
        let shouldStartWithHiddenSidebarForTerminalViewportUITest = false
#endif
        let sidebarState = SidebarState(
            isVisible: shouldStartWithHiddenSidebarForTerminalViewportUITest
                ? false
                : (sessionWindowSnapshot?.sidebar.isVisible ?? true),
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )

        // Seed the per-window Bonsplit tab-bar leading inset before ContentView first
        // renders. The initial workspace is created inside TabManager.init, at which
        // point there is no source workspace or prior window inset to inherit from, so
        // applyCreationChromeInheritance returns early and leaves the Bonsplit inset
        // at 0 — which is wrong in minimal mode with the sidebar collapsed, where the
        // native traffic lights need an 80pt reserved strip on the tab bar. Without
        // this seed, the first-frame layout can mispaint in the new window until
        // ContentView.onAppear eventually runs syncTrafficLightInset (#2737).
        let initialTabBarLeadingInset: CGFloat =
            (WorkspacePresentationModeSettings.isMinimal() && !sidebarState.isVisible)
                ? MinimalModeTitlebarDebugSettings.trafficLightTabBarLeadingInset()
                : 0
        tabManager.syncWorkspaceTabBarLeadingInset(initialTabBarLeadingInset)
        let notificationStore = TerminalNotificationStore.shared

        let cmuxConfigStore = CmuxConfigStore()
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()

        let fileExplorerState = FileExplorerState()
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] == "1" {
            fileExplorerState.mode = .files
            fileExplorerState.isVisible = true
        }
#endif

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environment(tabManager)
            .environment(notificationStore)
            .environment(sidebarState)
            .environment(sidebarSelectionState)
            .environment(fileExplorerState)
            .environment(cmuxConfigStore)
            // AppKit hosts this ContentView in its own NSHostingView, which does
            // not inherit the App scene's SwiftUI environment. Inject the
            // settings runtime so `@LiveSetting` can resolve the stores it
            // observes throughout the main window (e.g. the sidebar). The key is
            // optional, so a nil runtime just leaves reads at their seeded
            // catalog default.
            .environment(\.settingsRuntime, settingsRuntime)

        // Use the current key window's size for new windows so Cmd+Shift+N
        // creates a window matching the previous one's dimensions.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let sourceContext = preferredMainWindowContextForWorkspaceCreation(
            debugSource: "createMainWindow.initialGeometry"
        )
        let sourceWindow = resolvedMainWindowSource(preferredSourceWindow)
            ?? sourceContext.flatMap { resolvedWindow(for: $0) }
        let existingFrame = sourceWindow?.frame
        let sourceWindowIsNativeFullScreen: Bool = {
#if DEBUG
            if let debugCreateMainWindowSourceIsNativeFullScreenOverride {
                return debugCreateMainWindowSourceIsNativeFullScreenOverride
            }
#endif
            return sourceWindow?.styleMask.contains(.fullScreen) == true
        }()
        let shouldTemporarilyDisallowFullScreenTiling =
            sessionWindowSnapshot == nil && sourceWindowIsNativeFullScreen
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        let persistedGeometryFrame = (restoredFrame == nil && sourceWindow == nil)
            ? resolvedPersistedWindowGeometryFrame()
            : nil
        let initialRect: NSRect
        if restoredFrame == nil, let existingFrame {
            // Convert frame rect to content rect so the new window matches the
            // source window's actual size (frame includes titlebar insets).
            initialRect = NSWindow.contentRect(forFrameRect: existingFrame, styleMask: styleMask)
        } else if let explicitInitialFrame = restoredFrame ?? persistedGeometryFrame {
            initialRect = NSWindow.contentRect(forFrameRect: explicitInitialFrame, styleMask: styleMask)
        } else {
            initialRect = CmuxMainWindow.defaultContentRect(styleMask: styleMask)
        }

        let window = CmuxMainWindow(
            contentRect: initialRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        let minimumWindowSize = CmuxMainWindow.minimumContentSize
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.animationBehavior = .none
        // When creating a new window from an existing native fullscreen window,
        // temporarily opt out of fullscreen tiling so AppKit doesn't place the
        // new window into the active fullscreen Space.
        if shouldTemporarilyDisallowFullScreenTiling {
            window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // cmux persists and restores main windows itself. Disable AppKit window
        // restoration so the OS cannot resurrect stale duplicate main windows.
        window.isRestorable = false
        configureCmuxMainWindowDragBehavior(window)
        let explicitInitialFrame = restoredFrame ?? persistedGeometryFrame
        if let explicitInitialFrame {
            window.setFrame(explicitInitialFrame, display: false)
        } else if let sourceWindow {
            positionNewMainWindow(window, relativeTo: sourceWindow)
        } else {
            window.center()
            // Cascade using the same algorithm as upstream Ghostty: seed from
            // the window's own top-left on the first call, then advance the
            // cascade point for each subsequent window.
            if mainWindowContexts.count >= 1 {
                lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
            } else {
                lastCascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            }
        }
        window.contentView = MainWindowHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        controller.shouldClose = { [weak self] in
            let shouldClose = self?.handleMainTerminalWindowShouldClose() ?? true
            if !shouldClose {
                self?.closedWindowHistorySuppressedWindowIds.remove(windowId)
            }
            return shouldClose
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore
        )
        publishCmuxWindowLifecycle(name: "window.created", windowId: windowId, origin: "create")
        installFileDropOverlay(on: window, tabManager: tabManager)
        if !shouldActivate || TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if shouldActivate, TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            mainWindowVisibilityController.focus(
                window,
                reason: .createMainWindow,
                activation: .runningApplication([.activateAllWindows]),
                respectActivationSuppression: false
            )
        }
        if shouldTemporarilyDisallowFullScreenTiling {
            let clearFullScreenTilingOptOut: () -> Void = { [weak window] in
                guard let window else { return }
                window.collectionBehavior.remove(.fullScreenDisallowsTiling)
                if window.collectionBehavior.contains(.fullScreenDisallowsTiling) {
                    var behavior = window.collectionBehavior
                    behavior.remove(.fullScreenDisallowsTiling)
                    window.collectionBehavior = behavior
                }
            }
            RunLoop.main.perform {
                clearFullScreenTilingOptOut()
            }
            DispatchQueue.main.async {
                clearFullScreenTilingOptOut()
            }
        }
        if let explicitInitialFrame {
            window.setFrame(explicitInitialFrame, display: true)
#if DEBUG
            cmuxDebugLog(
                "mainWindow.initialFrameApplied source=\(restoredFrame == nil ? "persistedGeometry" : "sessionSnapshot") window=\(windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
        return windowId
    }

}
