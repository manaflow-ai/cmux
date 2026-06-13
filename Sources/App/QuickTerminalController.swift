import AppKit
import Foundation

@MainActor
final class QuickTerminalController {
    private enum AnimationPhase {
        case idle
        case showing
        case hiding
    }

    private enum PendingAnimationIntent {
        case show
        case hide
    }

    @MainActor
    struct Dependencies {
        var createMainWindow: @MainActor (AppDelegate, QuickTerminalPlacement, SessionWindowSnapshot?) -> UUID
        var windowForMainWindowId: @MainActor (AppDelegate, UUID) -> CmuxMainWindow?
        var focusQuickTerminalWindow: @MainActor (AppDelegate, CmuxMainWindow) -> Bool
        var beep: @MainActor () -> Void
        var animateFrame: @MainActor (
            NSWindow,
            NSRect,
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> Void

        static let live = Dependencies(
            createMainWindow: { appDelegate, placement, snapshot in
                appDelegate.createMainWindow(
                    initialWorkspaceTitle: String(localized: "quickTerminal.windowTitle", defaultValue: "Quick Terminal"),
                    sessionWindowSnapshot: snapshot,
                    shouldActivate: false,
                    initialFrame: placement.visibleFrame,
                    initialSidebarVisible: false,
                    shouldOrderFrontWhenNotActivating: false,
                    isQuickTerminal: true
                )
            },
            windowForMainWindowId: { appDelegate, windowId in
                appDelegate.windowForMainWindowId(windowId) as? CmuxMainWindow
            },
            focusQuickTerminalWindow: { appDelegate, window in
                appDelegate.focusQuickTerminalWindow(window)
            },
            beep: {
                NSSound.beep()
            },
            animateFrame: { window, frame, duration, completion in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    context.allowsImplicitAnimation = true
                    window.animator().setFrame(frame, display: true)
                } completionHandler: {
                    Task { @MainActor in
                        completion()
                    }
                }
            }
        )
    }

    private weak var appDelegate: AppDelegate?
    private var quickTerminalWindowId: UUID?
    private var pendingSessionSnapshot: SessionWindowSnapshot?
    private var animationPhase = AnimationPhase.idle
    private var pendingAnimationIntent: PendingAnimationIntent?
    private let configurationProvider: @MainActor () -> QuickTerminalConfiguration
    private let placementProvider: @MainActor (QuickTerminalConfiguration) -> QuickTerminalPlacement?
    private let dependencies: Dependencies

    init(
        appDelegate: AppDelegate,
        configurationProvider: @escaping @MainActor () -> QuickTerminalConfiguration = { QuickTerminalConfiguration.current() },
        placementProvider: @escaping @MainActor (QuickTerminalConfiguration) -> QuickTerminalPlacement? = { configuration in
            QuickTerminalPlacement.current(configuration: configuration)
        },
        dependencies: Dependencies? = nil
    ) {
        self.appDelegate = appDelegate
        self.configurationProvider = configurationProvider
        self.placementProvider = placementProvider
        self.dependencies = dependencies ?? Dependencies.live
    }

    func toggle() {
        if queueToggleIfAnimating() {
            return
        }

        let configuration = configurationProvider()
        guard let appDelegate,
              let placement = placementProvider(configuration) else {
            return
        }

        guard let window = quickTerminalWindow(appDelegate: appDelegate, placement: placement) else {
            dependencies.beep()
            return
        }

        if shouldHide(window) {
            hide(window, placement: placement, configuration: configuration)
        } else {
            show(window, placement: placement, configuration: configuration, appDelegate: appDelegate)
        }
    }

    func restoreSession(_ snapshot: SessionWindowSnapshot) {
        pendingSessionSnapshot = snapshot
    }

    func pendingSessionSnapshotForPersistence() -> SessionWindowSnapshot? {
        guard quickTerminalWindowId == nil else { return nil }
        return pendingSessionSnapshot
    }

    func handleWindowUnregistered(windowId: UUID, pendingSnapshot: SessionWindowSnapshot?) {
        guard quickTerminalWindowId == windowId else { return }
        quickTerminalWindowId = nil
        pendingAnimationIntent = nil
        animationPhase = .idle

        if var pendingSnapshot {
            pendingSnapshot.isQuickTerminal = true
            pendingSessionSnapshot = pendingSnapshot
        }
    }

    func hideFromCloseShortcut(_ window: CmuxMainWindow) {
        if queueHideIfAnimating() {
            return
        }

        let configuration = configurationProvider()
        guard let placement = placementProvider(configuration) else {
            window.orderOut(nil)
            window.setSoftHiddenForVisibilityController(true)
            return
        }
        hide(window, placement: placement, configuration: configuration)
    }

    private func shouldHide(_ window: NSWindow) -> Bool {
        isShown(window)
    }

    private func queueToggleIfAnimating() -> Bool {
        switch animationPhase {
        case .idle:
            return false
        case .showing:
            pendingAnimationIntent = .hide
            return true
        case .hiding:
            pendingAnimationIntent = .show
            return true
        }
    }

    private func queueHideIfAnimating() -> Bool {
        switch animationPhase {
        case .idle:
            return false
        case .showing:
            pendingAnimationIntent = .hide
            return true
        case .hiding:
            pendingAnimationIntent = nil
            return true
        }
    }

    private func runPendingAnimationIntent() {
        guard let pendingAnimationIntent else { return }
        self.pendingAnimationIntent = nil

        let configuration = configurationProvider()
        guard let appDelegate,
              let placement = placementProvider(configuration) else {
            return
        }

        guard let window = quickTerminalWindow(appDelegate: appDelegate, placement: placement) else {
            dependencies.beep()
            return
        }

        switch pendingAnimationIntent {
        case .show:
            show(window, placement: placement, configuration: configuration, appDelegate: appDelegate)
        case .hide:
            hide(window, placement: placement, configuration: configuration)
        }
    }

    private func isShown(_ window: NSWindow) -> Bool {
        window.isVisible &&
            !window.isMiniaturized &&
            window.alphaValue > 0.001
    }

    private func quickTerminalWindow(
        appDelegate: AppDelegate,
        placement: QuickTerminalPlacement
    ) -> CmuxMainWindow? {
        if let quickTerminalWindowId,
           let window = appDelegate.windowForMainWindowId(quickTerminalWindowId) as? CmuxMainWindow {
            configure(window)
            return window
        }

        let snapshot = pendingSessionSnapshot
        let windowId = dependencies.createMainWindow(appDelegate, placement, snapshot)
        guard let window = dependencies.windowForMainWindowId(appDelegate, windowId) else {
            return nil
        }
        pendingSessionSnapshot = nil
        quickTerminalWindowId = windowId
        configure(window)
        window.setSoftHiddenForVisibilityController(true)
        window.orderOut(nil)
#if DEBUG
        cmuxDebugLog("quickTerminal.create windowId=\(String(windowId.uuidString.prefix(8))) frame={\(NSStringFromRect(placement.visibleFrame))}")
#endif
        return window
    }

    private func configure(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.quickTerminal")
        window.level = .floating
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .transient])
        window.isExcludedFromWindowsMenu = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func show(
        _ window: CmuxMainWindow,
        placement: QuickTerminalPlacement,
        configuration: QuickTerminalConfiguration,
        appDelegate: AppDelegate
    ) {
        configure(window)
        if isShown(window) {
            window.setSoftHiddenForVisibilityController(false)
            _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
            return
        }

        animationPhase = .showing
        window.setFrame(placement.hiddenFrame, display: false)
        window.setSoftHiddenForVisibilityController(false)
        _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
#if DEBUG
        cmuxDebugLog("quickTerminal.show frame={\(NSStringFromRect(placement.visibleFrame))}")
#endif
        dependencies.animateFrame(window, placement.visibleFrame, configuration.animationDuration) { [weak self] in
            guard let self else { return }
            self.animationPhase = .idle
            self.runPendingAnimationIntent()
        }
    }

    private func hide(
        _ window: CmuxMainWindow,
        placement: QuickTerminalPlacement,
        configuration: QuickTerminalConfiguration
    ) {
        if placement.hiddenFrame.equalTo(placement.visibleFrame) {
            completeHide(window, placement: placement)
            return
        }

        animationPhase = .hiding
#if DEBUG
        cmuxDebugLog("quickTerminal.hide frame={\(NSStringFromRect(placement.hiddenFrame))}")
#endif
        dependencies.animateFrame(window, placement.hiddenFrame, configuration.animationDuration * 0.8) { [weak self, window] in
            guard let self else { return }
            self.completeHide(window, placement: placement)
            self.runPendingAnimationIntent()
        }
    }

    private func completeHide(_ window: CmuxMainWindow, placement: QuickTerminalPlacement) {
        window.orderOut(nil)
        window.setFrame(placement.visibleFrame, display: false)
        window.setSoftHiddenForVisibilityController(true)
        animationPhase = .idle
    }
}
