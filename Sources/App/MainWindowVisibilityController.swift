import AppKit
import Foundation

@MainActor
final class MainWindowVisibilityController {
    enum Reason: String {
        case createMainWindow
        case applicationDidBecomeActive
        case applicationWillBecomeActive
        case applicationReopen
        case ensureInitialWindow
        case feedback
        case fileSearchFocus
        case findShortcut
        case focusMainWindow
        case globalHotkey
        case menuBar
        case notification
        case rightSidebarFocus
        case rightSidebarToggle
        case titlebarDismiss
        case socketActivate
        case workspaceCreation
    }

    enum Activation {
        case none
        case runningApplication(NSApplication.ActivationOptions)
    }

    enum ActivationTiming {
        case beforeWindowOrdering
        case afterWindowOrdering
    }

    @MainActor
    struct WindowOperations {
        var isVisible: @MainActor (NSWindow) -> Bool
        var isMiniaturized: @MainActor (NSWindow) -> Bool
        var isKeyWindow: @MainActor (NSWindow) -> Bool
        var canBecomeMain: @MainActor (NSWindow) -> Bool
        var canBecomeKey: @MainActor (NSWindow) -> Bool
        var deminiaturize: @MainActor (NSWindow) -> Void
        var makeKeyAndOrderFront: @MainActor (NSWindow) -> Void
        var makeKey: @MainActor (NSWindow) -> Void
        var orderFront: @MainActor (NSWindow) -> Void
        var orderFrontRegardless: @MainActor (NSWindow) -> Void
        var orderOut: @MainActor (NSWindow) -> Void
        var softHide: @MainActor (NSWindow) -> Void
        var softShow: @MainActor (NSWindow) -> Void

        static let live = WindowOperations(
            isVisible: { $0.isVisible && $0.alphaValue > 0.001 },
            isMiniaturized: { $0.isMiniaturized },
            isKeyWindow: { $0.isKeyWindow },
            canBecomeMain: { $0.canBecomeMain },
            canBecomeKey: { $0.canBecomeKey },
            deminiaturize: { $0.deminiaturize(nil) },
            makeKeyAndOrderFront: { $0.makeKeyAndOrderFront(nil) },
            makeKey: { $0.makeKey() },
            orderFront: { $0.orderFront(nil) },
            orderFrontRegardless: { $0.orderFrontRegardless() },
            orderOut: { $0.orderOut(nil) },
            softHide: {
                if let window = $0 as? CmuxMainWindow {
                    window.setSoftHiddenForVisibilityController(true)
                } else {
                    $0.makeFirstResponder(nil)
                    $0.ignoresMouseEvents = true
                    $0.alphaValue = 0
                }
            },
            softShow: {
                if let window = $0 as? CmuxMainWindow {
                    window.setSoftHiddenForVisibilityController(false)
                } else {
                    $0.alphaValue = 1
                    $0.ignoresMouseEvents = false
                }
            }
        )
    }

    @MainActor
    struct Dependencies {
        var isActivationSuppressed: @MainActor () -> Bool
        var setActiveMainWindow: @MainActor (NSWindow) -> Void
        var isApplicationActive: @MainActor () -> Bool
        var isApplicationHidden: @MainActor () -> Bool
        var keyWindow: @MainActor () -> NSWindow?
        var mainWindow: @MainActor () -> NSWindow?
        var hideApplication: @MainActor () -> Void
        var unhideApplication: @MainActor () -> Void
        var activateRunningApplication: @MainActor (NSApplication.ActivationOptions) -> Void
        var windowOperations: WindowOperations

        init(
            isActivationSuppressed: @escaping @MainActor () -> Bool,
            setActiveMainWindow: @escaping @MainActor (NSWindow) -> Void,
            isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
            isApplicationHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden },
            keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
            mainWindow: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow },
            hideApplication: @escaping @MainActor () -> Void = { NSApp.hide(nil) },
            unhideApplication: @escaping @MainActor () -> Void = { NSApp.unhide(nil) },
            activateRunningApplication: @escaping @MainActor (NSApplication.ActivationOptions) -> Void = {
                NSRunningApplication.current.activate(options: $0)
            },
            windowOperations: WindowOperations? = nil
        ) {
            self.isActivationSuppressed = isActivationSuppressed
            self.setActiveMainWindow = setActiveMainWindow
            self.isApplicationActive = isApplicationActive
            self.isApplicationHidden = isApplicationHidden
            self.keyWindow = keyWindow
            self.mainWindow = mainWindow
            self.hideApplication = hideApplication
            self.unhideApplication = unhideApplication
            self.activateRunningApplication = activateRunningApplication
            self.windowOperations = windowOperations ?? WindowOperations.live
        }
    }

    private var dependencies: Dependencies
    private var appHiddenWindowRestoreTargets: [NSWindow] = []
    private var dismissedWindowRestoreTargets: [NSWindow] = []
    private var pendingApplicationActivationKeyRestoreTarget: NSWindow?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @discardableResult
    func focus(
        _ window: NSWindow,
        reason: Reason,
        activation: Activation = .runningApplication([.activateAllWindows]),
        activationTiming: ActivationTiming = .afterWindowOrdering,
        makeKey: Bool = true,
        deminiaturize: Bool = true,
        unhide: Bool = true,
        respectActivationSuppression: Bool = true
    ) -> Bool {
        if respectActivationSuppression, dependencies.isActivationSuppressed() {
            dependencies.setActiveMainWindow(window)
            log("focus.suppressed", reason: reason, windows: [window])
            return true
        }

        dependencies.setActiveMainWindow(window)
        if unhide, dependencies.isApplicationHidden() {
            trace("focus.unhide.begin", reason: reason, windows: [window])
            dependencies.unhideApplication()
            trace("focus.unhide.end", reason: reason, windows: [window])
        }
        let effectiveActivation = activationRequiringKeyTransfer(activation, makeKey: makeKey)

        if activationTiming == .beforeWindowOrdering {
            activate(effectiveActivation)
        }
        let shouldActivateBeforeWindowOrdering = activationTiming == .afterWindowOrdering &&
            deminiaturize &&
            dependencies.windowOperations.isMiniaturized(window)
        if shouldActivateBeforeWindowOrdering {
            trace("focus.activate.beforeMiniaturize.begin", reason: reason, windows: [window])
            activate(effectiveActivation)
            trace("focus.activate.beforeMiniaturize.end", reason: reason, windows: [window])
        }
        if deminiaturize, dependencies.windowOperations.isMiniaturized(window) {
            trace("focus.deminiaturize.begin", reason: reason, windows: [window])
            dependencies.windowOperations.deminiaturize(window)
            trace("focus.deminiaturize.end", reason: reason, windows: [window])
        }
        dependencies.windowOperations.softShow(window)
        if makeKey {
            trace("focus.orderFront.begin", reason: reason, windows: [window])
            dependencies.windowOperations.makeKeyAndOrderFront(window)
            trace("focus.orderFront.end", reason: reason, windows: [window])
        } else {
            trace("focus.orderFront.begin", reason: reason, windows: [window])
            dependencies.windowOperations.orderFront(window)
            trace("focus.orderFront.end", reason: reason, windows: [window])
        }
        if activationTiming == .afterWindowOrdering && !shouldActivateBeforeWindowOrdering {
            trace("focus.activate.begin", reason: reason, windows: [window])
            activate(effectiveActivation)
            trace("focus.activate.end", reason: reason, windows: [window])
        }
        log("focus", reason: reason, windows: [window])
        return true
    }

    func focusForInWindowCommand(_ window: NSWindow, reason: Reason) {
        dependencies.setActiveMainWindow(window)
        guard !dependencies.windowOperations.isKeyWindow(window) else {
            log("focus.inWindow.key", reason: reason, windows: [window])
            return
        }
        if dependencies.isApplicationHidden() {
            trace("focus.inWindow.unhide.begin", reason: reason, windows: [window])
            dependencies.unhideApplication()
            trace("focus.inWindow.unhide.end", reason: reason, windows: [window])
        }
        if !dependencies.isApplicationActive() {
            trace("focus.inWindow.activate.begin", reason: reason, windows: [window])
            activate(.runningApplication([.activateAllWindows]))
            trace("focus.inWindow.activate.end", reason: reason, windows: [window])
        }
        if dependencies.windowOperations.isMiniaturized(window) {
            trace("focus.inWindow.deminiaturize.begin", reason: reason, windows: [window])
            dependencies.windowOperations.deminiaturize(window)
            trace("focus.inWindow.deminiaturize.end", reason: reason, windows: [window])
        }
        dependencies.windowOperations.softShow(window)
        trace("focus.inWindow.orderFront.begin", reason: reason, windows: [window])
        dependencies.windowOperations.makeKeyAndOrderFront(window)
        trace("focus.inWindow.orderFront.end", reason: reason, windows: [window])
        log("focus.inWindow", reason: reason, windows: [window])
    }

    func captureHiddenWindowRestoreTargets(windows: [NSWindow], reason: Reason = .globalHotkey) {
        appHiddenWindowRestoreTargets = uniqueWindows(windows).filter { window in
            dependencies.windowOperations.isVisible(window) && !dependencies.windowOperations.isMiniaturized(window)
        }
        log("hide.capture", reason: reason, windows: appHiddenWindowRestoreTargets)
    }

    func dismissWindows(
        windows: [NSWindow],
        reason: Reason = .titlebarDismiss
    ) {
        let windows = uniqueWindows(windows)
        guard !windows.isEmpty else {
            log("dismiss.empty", reason: reason, windows: [])
            return
        }

        let restoreTargets = windows.filter { window in
            dependencies.windowOperations.isVisible(window) && !dependencies.windowOperations.isMiniaturized(window)
        }
        dismissedWindowRestoreTargets = mergeDismissedWindowRestoreTargets(with: restoreTargets)
        log("dismiss.capture", reason: reason, windows: dismissedWindowRestoreTargets)
        for window in windows where dependencies.windowOperations.isVisible(window) {
            trace("dismiss.softHide.begin", reason: reason, windows: [window])
            dependencies.windowOperations.softHide(window)
            trace("dismiss.softHide.end", reason: reason, windows: [window])
        }
        log("dismiss", reason: reason, windows: windows)
    }

    func toggleApplicationVisibility(windows: [NSWindow], reason: Reason = .globalHotkey) {
        let windows = uniqueWindows(windows)
        let isFrontmost = dependencies.isApplicationActive() && !dependencies.isApplicationHidden()
        let hasVisibleWindow = windows.contains { window in
            dependencies.windowOperations.isVisible(window) && !dependencies.windowOperations.isMiniaturized(window)
        }

        if isFrontmost && hasVisibleWindow {
            captureHiddenWindowRestoreTargets(windows: windows, reason: reason)
            dependencies.hideApplication()
            log("toggle.hide", reason: reason, windows: windows)
            return
        }

        _ = showApplicationWindows(windows: windows, reason: reason)
    }

    @discardableResult
    func showApplicationWindows(
        windows allWindows: [NSWindow],
        reason: Reason = .globalHotkey,
        activation: Activation = .runningApplication([.activateAllWindows]),
        makeKey: Bool = true,
        consumeDismissedWindowRestoreTargets: Bool = true
    ) -> NSWindow? {
        let allWindows = uniqueWindows(allWindows)
        let visibleOrMiniaturizedTargets = allWindows.filter { window in
            dependencies.windowOperations.isVisible(window) || dependencies.windowOperations.isMiniaturized(window)
        }
        let revealTargets: [NSWindow]

        if dependencies.isApplicationHidden() {
            dependencies.unhideApplication()
            let capturedTargets = appHiddenWindowRestoreTargets.filter { capturedWindow in
                allWindows.contains { $0 === capturedWindow }
            }
            let dismissedTargets = dismissedWindowRestoreTargets.filter { dismissedWindow in
                allWindows.contains { $0 === dismissedWindow }
            }
            appHiddenWindowRestoreTargets.removeAll()
            if !capturedTargets.isEmpty {
                revealTargets = capturedTargets
            } else if !dismissedTargets.isEmpty {
                revealTargets = dismissedTargets
            } else {
                revealTargets = allWindows.filter { dependencies.windowOperations.isMiniaturized($0) }
            }
        } else if !visibleOrMiniaturizedTargets.isEmpty {
            revealTargets = visibleOrMiniaturizedTargets
        } else {
            let dismissedTargets = dismissedWindowRestoreTargets.filter { dismissedWindow in
                allWindows.contains { $0 === dismissedWindow }
            }
            dismissedWindowRestoreTargets.removeAll()
            revealTargets = dismissedTargets
        }

        trace("show.begin", reason: reason, windows: revealTargets)

        let focusWindow = reveal(
            revealTargets,
            preferredWindow: nil,
            reason: reason,
            activation: activation,
            makeKey: makeKey
        )
        if consumeDismissedWindowRestoreTargets {
            dismissedWindowRestoreTargets.removeAll { dismissedWindow in
                revealTargets.contains { $0 === dismissedWindow }
            }
        }
        return focusWindow
    }

    @discardableResult
    func orderFrontApplicationWindowsBeforeActivation(windows: [NSWindow], reason: Reason) -> NSWindow? {
        let revealTargets = passiveApplicationActivationRestoreTargets(in: uniqueWindows(windows))
        let focusWindow = reveal(revealTargets, preferredWindow: nil, reason: reason, activation: .none, makeKey: false)
        pendingApplicationActivationKeyRestoreTarget = focusWindow
        return focusWindow
    }

    @discardableResult
    func restoreApplicationWindowsAfterActivation(windows: [NSWindow], reason: Reason) -> NSWindow? {
        let revealTargets = passiveApplicationActivationRestoreTargets(in: uniqueWindows(windows))
        let focusWindow = reveal(revealTargets, preferredWindow: nil, reason: reason, activation: .none)
        dismissedWindowRestoreTargets.removeAll { dismissedWindow in
            revealTargets.contains { $0 === dismissedWindow }
        }
        return focusWindow
    }

    @discardableResult
    func finishPendingApplicationActivationRestore(windows: [NSWindow], reason: Reason) -> NSWindow? {
        let allWindows = uniqueWindows(windows)
        guard let pending = pendingApplicationActivationKeyRestoreTarget,
              allWindows.contains(where: { $0 === pending }) else {
            pendingApplicationActivationKeyRestoreTarget = nil
            return nil
        }
        pendingApplicationActivationKeyRestoreTarget = nil
        let focusWindow = reveal(
            [pending],
            preferredWindow: pending,
            reason: reason,
            activation: .none
        )
        dismissedWindowRestoreTargets.removeAll { dismissed in
            allWindows.contains { $0 === dismissed } &&
                dependencies.windowOperations.isVisible(dismissed) &&
                !dependencies.windowOperations.isMiniaturized(dismissed)
        }
        return focusWindow
    }

    @discardableResult
    func reveal(
        _ windows: [NSWindow],
        preferredWindow: NSWindow?,
        reason: Reason,
        activation: Activation = .runningApplication([.activateAllWindows]),
        makeKey: Bool = true
    ) -> NSWindow? {
        let windows = uniqueWindows(windows).filter { window in
            makeKey || !dependencies.windowOperations.isMiniaturized(window)
        }
        guard !windows.isEmpty else {
            log("reveal.empty", reason: reason, windows: [])
            return nil
        }

        for window in windows where dependencies.windowOperations.isMiniaturized(window) {
            trace("reveal.deminiaturize.begin", reason: reason, windows: [window])
            dependencies.windowOperations.deminiaturize(window)
            trace("reveal.deminiaturize.end", reason: reason, windows: [window])
        }
        for window in windows {
            dependencies.windowOperations.softShow(window)
        }
        let effectiveActivation = activationRequiringKeyTransfer(activation, makeKey: makeKey)
        trace("reveal.activate.begin", reason: reason, windows: windows)
        activate(effectiveActivation)
        trace("reveal.activate.end", reason: reason, windows: windows)

        let focusWindow = resolvedPreferredFocusWindow(preferredWindow: preferredWindow, in: windows)
        if let focusWindow {
            dependencies.setActiveMainWindow(focusWindow)
            if makeKey {
                trace("reveal.makeKey.begin", reason: reason, windows: [focusWindow])
                dependencies.windowOperations.orderFrontRegardless(focusWindow)
                dependencies.windowOperations.makeKey(focusWindow)
                trace("reveal.makeKey.end", reason: reason, windows: [focusWindow])
            } else {
                trace("reveal.orderFrontOnly.begin", reason: reason, windows: [focusWindow])
                dependencies.windowOperations.orderFrontRegardless(focusWindow)
                trace("reveal.orderFrontOnly.end", reason: reason, windows: [focusWindow])
            }
        }

        for window in windows where window !== focusWindow {
            trace("reveal.orderFrontRegardless.begin", reason: reason, windows: [window])
            dependencies.windowOperations.orderFrontRegardless(window)
            trace("reveal.orderFrontRegardless.end", reason: reason, windows: [window])
        }

        log("reveal", reason: reason, windows: windows)
        return focusWindow
    }

    private func passiveApplicationActivationRestoreTargets(in allWindows: [NSWindow]) -> [NSWindow] {
        let capturedTargets = appHiddenWindowRestoreTargets.filter { capturedWindow in
            allWindows.contains { $0 === capturedWindow } &&
                !dependencies.windowOperations.isMiniaturized(capturedWindow)
        }
        let dismissedTargets = dismissedWindowRestoreTargets.filter { dismissedWindow in
            allWindows.contains { $0 === dismissedWindow } &&
                !dependencies.windowOperations.isMiniaturized(dismissedWindow)
        }

        if dependencies.isApplicationHidden() {
            dependencies.unhideApplication()
        }

        if !capturedTargets.isEmpty {
            appHiddenWindowRestoreTargets.removeAll { capturedWindow in
                capturedTargets.contains { $0 === capturedWindow }
            }
            return capturedTargets
        }
        return dismissedTargets
    }

    private func resolvedPreferredFocusWindow(preferredWindow: NSWindow?, in windows: [NSWindow]) -> NSWindow? {
        if let preferredWindow, windows.contains(where: { $0 === preferredWindow }) {
            return preferredWindow
        }
        if let keyWindow = dependencies.keyWindow(), windows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }
        if let mainWindow = dependencies.mainWindow(), windows.contains(where: { $0 === mainWindow }) {
            return mainWindow
        }
        return windows.first(where: dependencies.windowOperations.canBecomeMain)
            ?? windows.first(where: dependencies.windowOperations.canBecomeKey)
            ?? windows.first
    }

    private func activate(_ activation: Activation) {
        switch activation {
        case .none:
            break
        case .runningApplication(let options):
            dependencies.activateRunningApplication(options)
        }
    }

    private func activationRequiringKeyTransfer(_ activation: Activation, makeKey: Bool) -> Activation {
        makeKey ? activation : .none
    }

    private func uniqueWindows(_ windows: [NSWindow]) -> [NSWindow] {
        var result: [NSWindow] = []
        for window in windows where !result.contains(where: { $0 === window }) {
            result.append(window)
        }
        return result
    }

    private func mergeDismissedWindowRestoreTargets(with windows: [NSWindow]) -> [NSWindow] {
        var result = dismissedWindowRestoreTargets
        for window in windows where !result.contains(where: { $0 === window }) {
            result.append(window)
        }
        return result
    }

    private func log(_ event: String, reason: Reason, windows: [NSWindow]) {
#if DEBUG
        let windowTokens = windows.map { window -> String in
            let id = window.identifier?.rawValue ?? "<nil>"
            return "\(id):visible=\(dependencies.windowOperations.isVisible(window) ? 1 : 0):mini=\(dependencies.windowOperations.isMiniaturized(window) ? 1 : 0):key=\(dependencies.windowOperations.isKeyWindow(window) ? 1 : 0)"
        }
        cmuxDebugLog("mainWindow.visibility.\(event) reason=\(reason.rawValue) windows=[\(windowTokens.joined(separator: ","))]")
#endif
    }

    private func trace(_ event: String, reason: Reason, windows: [NSWindow]) {
#if DEBUG
        let windowTokens = windows.map { window -> String in
            let id = window.identifier?.rawValue ?? "<nil>"
            return "\(id):visible=\(dependencies.windowOperations.isVisible(window) ? 1 : 0):mini=\(dependencies.windowOperations.isMiniaturized(window) ? 1 : 0):key=\(dependencies.windowOperations.isKeyWindow(window) ? 1 : 0)"
        }
        cmuxDebugLog("mainWindow.visibility.\(event) reason=\(reason.rawValue) windows=[\(windowTokens.joined(separator: ","))]")
#endif
    }
}

enum QuickTerminalPosition: String {
    case top
    case bottom
    case left
    case right
    case center
}

struct QuickTerminalConfiguration: Equatable {
    static let fallback = QuickTerminalConfiguration(
        position: .top,
        screenFraction: 0.46,
        animationDuration: 0.18
    )

    var position: QuickTerminalPosition
    var screenFraction: CGFloat
    var animationDuration: TimeInterval

    init(
        position: QuickTerminalPosition,
        screenFraction: CGFloat,
        animationDuration: TimeInterval
    ) {
        self.position = position
        self.screenFraction = min(max(screenFraction, 0.2), 0.95)
        self.animationDuration = min(max(animationDuration, 0.05), 0.6)
    }

    static func current(loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() }) -> QuickTerminalConfiguration {
        let config = loadConfig()
        return QuickTerminalConfiguration(
            position: config.quickTerminalPosition.flatMap(QuickTerminalPosition.init(rawValue:)) ?? fallback.position,
            screenFraction: CGFloat(config.quickTerminalScreenFraction ?? Double(fallback.screenFraction)),
            animationDuration: config.quickTerminalAnimationDuration ?? fallback.animationDuration
        )
    }
}

@MainActor
struct QuickTerminalPlacement: Equatable {
    static let defaultTopInsetRange: ClosedRange<CGFloat> = 8...16

    let visibleFrame: NSRect
    let hiddenFrame: NSRect

    static func placement(
        forVisibleFrame visibleFrame: NSRect,
        configuration: QuickTerminalConfiguration = .fallback
    ) -> QuickTerminalPlacement {
        let topInset = min(max(visibleFrame.height * 0.015, defaultTopInsetRange.lowerBound), defaultTopInsetRange.upperBound)
        let preferredHorizontalInset = min(max(visibleFrame.width * 0.06, 32), 96)
        let horizontalInset = min(preferredHorizontalInset, max(0, (visibleFrame.width - 1) / 2))
        let verticalInset = min(max(visibleFrame.height * 0.04, 24), 96)

        let shown: NSRect
        let hidden: NSRect
        switch configuration.position {
        case .top:
            let width = max(1, visibleFrame.width - horizontalInset * 2)
            let maxHeight = max(1, visibleFrame.height - topInset)
            let minHeight = min(420, maxHeight)
            let height = min(max(minHeight, visibleFrame.height * configuration.screenFraction), maxHeight)
            let x = visibleFrame.minX + (visibleFrame.width - width) / 2
            let y = visibleFrame.maxY - topInset - height
            shown = NSRect(x: x, y: y, width: width, height: height)
            hidden = NSRect(x: x, y: visibleFrame.maxY + topInset, width: width, height: height)
        case .bottom:
            let width = max(1, visibleFrame.width - horizontalInset * 2)
            let maxHeight = max(1, visibleFrame.height - topInset)
            let minHeight = min(420, maxHeight)
            let height = min(max(minHeight, visibleFrame.height * configuration.screenFraction), maxHeight)
            let x = visibleFrame.minX + (visibleFrame.width - width) / 2
            let y = visibleFrame.minY + topInset
            shown = NSRect(x: x, y: y, width: width, height: height)
            hidden = NSRect(x: x, y: visibleFrame.minY - height - topInset, width: width, height: height)
        case .left:
            let maxWidth = max(1, visibleFrame.width - horizontalInset)
            let width = min(max(420, visibleFrame.width * configuration.screenFraction), maxWidth)
            let height = max(1, visibleFrame.height - verticalInset * 2)
            let y = visibleFrame.minY + verticalInset
            shown = NSRect(x: visibleFrame.minX + topInset, y: y, width: width, height: height)
            hidden = NSRect(x: visibleFrame.minX - width - topInset, y: y, width: width, height: height)
        case .right:
            let maxWidth = max(1, visibleFrame.width - horizontalInset)
            let width = min(max(420, visibleFrame.width * configuration.screenFraction), maxWidth)
            let height = max(1, visibleFrame.height - verticalInset * 2)
            let y = visibleFrame.minY + verticalInset
            shown = NSRect(x: visibleFrame.maxX - width - topInset, y: y, width: width, height: height)
            hidden = NSRect(x: visibleFrame.maxX + topInset, y: y, width: width, height: height)
        case .center:
            let width = max(1, visibleFrame.width * 0.82)
            let height = max(1, visibleFrame.height * 0.82)
            shown = NSRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
            hidden = shown
        }
        return QuickTerminalPlacement(visibleFrame: shown, hiddenFrame: hidden)
    }

    static func current(configuration: QuickTerminalConfiguration = .current()) -> QuickTerminalPlacement? {
        guard let screen = preferredScreen() else { return nil }
        return placement(forVisibleFrame: screen.visibleFrame, configuration: configuration)
    }

    private static func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        if let mainScreen = NSScreen.main {
            return mainScreen
        }
        return NSScreen.screens.first
    }
}

@MainActor
final class QuickTerminalController {
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
    private var isAnimating = false
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
        let configuration = configurationProvider()
        guard !isAnimating,
              let appDelegate,
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

    func hideFromCloseShortcut(_ window: CmuxMainWindow) {
        guard !isAnimating else { return }
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

        isAnimating = true
        window.setFrame(placement.hiddenFrame, display: false)
        window.setSoftHiddenForVisibilityController(false)
        _ = dependencies.focusQuickTerminalWindow(appDelegate, window)
#if DEBUG
        cmuxDebugLog("quickTerminal.show frame={\(NSStringFromRect(placement.visibleFrame))}")
#endif
        dependencies.animateFrame(window, placement.visibleFrame, configuration.animationDuration) { [weak self] in
            self?.isAnimating = false
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

        isAnimating = true
#if DEBUG
        cmuxDebugLog("quickTerminal.hide frame={\(NSStringFromRect(placement.hiddenFrame))}")
#endif
        dependencies.animateFrame(window, placement.hiddenFrame, configuration.animationDuration * 0.8) { [weak self, window] in
            guard let self else { return }
            self.completeHide(window, placement: placement)
        }
    }

    private func completeHide(_ window: CmuxMainWindow, placement: QuickTerminalPlacement) {
        window.orderOut(nil)
        window.setFrame(placement.visibleFrame, display: false)
        window.setSoftHiddenForVisibilityController(true)
        isAnimating = false
    }
}
