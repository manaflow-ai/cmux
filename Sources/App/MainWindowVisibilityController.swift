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
        if activationTiming == .beforeWindowOrdering {
            activate(activation)
        }
        let shouldActivateBeforeWindowOrdering = activationTiming == .afterWindowOrdering &&
            deminiaturize &&
            dependencies.windowOperations.isMiniaturized(window)
        if shouldActivateBeforeWindowOrdering {
            trace("focus.activate.beforeMiniaturize.begin", reason: reason, windows: [window])
            activate(activation)
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
            activate(activation)
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
        let windows = uniqueWindows(windows)
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
        trace("reveal.activate.begin", reason: reason, windows: windows)
        activate(activation)
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
