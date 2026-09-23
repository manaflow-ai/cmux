import AppKit
import ApplicationServices
import Foundation

// AXObserver requires a C callback. The refcon is a +1 reference the session
// takes when it installs the observer and drops only after removing the
// observer's run loop source, so the pointer is always valid here.
private func foreignWindowAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    _ = observer
    _ = element
    guard let refcon else { return }
    let session = Unmanaged<ForeignWindowSession>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let name = notification as String
    if Thread.isMainThread {
        // The source is added to the main run loop, so this is the usual path.
        MainActor.assumeIsolated {
            session.handleAccessibilityNotification(name)
        }
    } else {
        Task { @MainActor in
            session.handleAccessibilityNotification(name)
        }
    }
}

/// Owns one external application process (one per profile) and glues its
/// main window over whichever host rect the registry says is presenting.
///
/// AX writes are cross-process IPC, so presentation updates are coalesced to
/// one apply per main run loop turn and skipped when the target is unchanged.
@MainActor
final class ForeignWindowSession: ForeignWindowProfileSession {
    private static let frameTolerance: CGFloat = 1
    /// Snap-back attempts per target rect, so an app that enforces its own
    /// minimum size cannot put us in a set/notify loop.
    private static let maximumCorrectionsPerTarget = 3
    private static let windowNotificationNames: [String] = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification
    ]

    private let identifier: String
    private let launchConfiguration: ForeignWindowLaunchConfiguration
    private var launchTask: Task<Void, Never>?
    private var isLaunchAllowed = true
    private var isInvalidated = false
    private var runningApplication: NSRunningApplication?
    private var applicationElement: AXUIElement?
    private var externalWindow: AXUIElement?
    private var observedWindow: AXUIElement?
    private var accessibilityObserver: AXObserver?
    private var observerRefcon: Unmanaged<ForeignWindowSession>?
    private var accessibilityPromptRequested = false
    private var isAccessibilityTrusted = false

    private var targetFrame: CGRect?
    private var shouldBeVisible = false
    private var shouldBeFocused = false
    private var lastAppliedFrame: CGRect?
    private var correctionsForTarget = 0
    private var pendingActivate = false
    private var pendingRaise = false
    private var isApplyScheduled = false

    private var yieldObserver: NSObjectProtocol?
    private var isHiddenForYield = false
    /// `NSRunningApplication.isHidden` updates asynchronously, so remember
    /// that we asked for a hide and always pair it with an unhide.
    private var didRequestHide = false

    init(
        identifier: String,
        launchConfiguration: ForeignWindowLaunchConfiguration
    ) {
        self.identifier = identifier
        self.launchConfiguration = launchConfiguration
        yieldObserver = NotificationCenter.default.addObserver(
            forName: ForeignWindowYieldCoordinator.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.yieldStateDidChange()
            }
        }
    }

    var isRunning: Bool {
        guard let runningApplication else { return false }
        return !runningApplication.isTerminated
    }

    private var isYielding: Bool {
        ForeignWindowYieldCoordinator.shared.isYielding
    }

    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    ) {
        guard !isInvalidated else { return }
        let becameFocused = isFocused && !shouldBeFocused
        let becameVisible = isVisible && !shouldBeVisible
        if targetFrame != self.targetFrame {
            correctionsForTarget = 0
        }
        self.targetFrame = targetFrame
        shouldBeVisible = isVisible
        shouldBeFocused = isFocused
        pendingActivate = pendingActivate || becameFocused
        pendingRaise = pendingRaise || raiseWindow || becameVisible
        if becameVisible || becameFocused {
            // Allow one relaunch per explicit show after the user quit the app.
            isLaunchAllowed = true
        }
        scheduleApply()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        launchTask?.cancel()
        launchTask = nil
        if let yieldObserver {
            NotificationCenter.default.removeObserver(yieldObserver)
        }
        yieldObserver = nil
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil

        if let runningApplication, !runningApplication.isTerminated {
            runningApplication.terminate()
        }
        runningApplication = nil
    }

    func handleAccessibilityNotification(_ name: String) {
        guard !isInvalidated else { return }
        switch name {
        case kAXWindowCreatedNotification:
            guard refreshExternalWindow() else { return }
            lastAppliedFrame = nil
            pendingRaise = true
            pendingActivate = pendingActivate || shouldBeFocused
            scheduleApply()
        case kAXUIElementDestroyedNotification:
            unregisterWindowNotifications()
            externalWindow = nil
            lastAppliedFrame = nil
            if refreshExternalWindow() {
                pendingRaise = true
                scheduleApply()
            }
        case kAXMovedNotification, kAXResizedNotification:
            snapBackIfDisplaced()
        default:
            break
        }
    }

    // MARK: Coalesced apply

    private func scheduleApply() {
        guard !isApplyScheduled, !isInvalidated else { return }
        isApplyScheduled = true
        // The main queue drains in common modes, including event tracking,
        // so this also runs once per turn during divider drags.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPresentation()
            }
        }
    }

    private func flushPresentation() {
        isApplyScheduled = false
        guard !isInvalidated else { return }
        if let runningApplication, runningApplication.isTerminated {
            handleApplicationTerminated()
        }
        guard runningApplication != nil else {
            if shouldBeVisible {
                startIfNeeded()
            }
            return
        }
        ensureAccessibilityBinding()
        applyPresentation()
    }

    private func yieldStateDidChange() {
        guard !isInvalidated, let runningApplication,
              !runningApplication.isTerminated else {
            return
        }
        if isYielding {
            // Hide immediately so floating cmux UI is never covered.
            if shouldBeVisible {
                hideApplication(runningApplication)
                isHiddenForYield = true
            }
        } else if isHiddenForYield {
            isHiddenForYield = false
            // Restore and re-raise without activating the external app.
            pendingRaise = true
            scheduleApply()
        }
    }

    // MARK: Launch

    private func startIfNeeded() {
        guard !isInvalidated,
              isLaunchAllowed,
              launchTask == nil,
              runningApplication == nil else {
            return
        }
        isLaunchAllowed = false

        guard let applicationURL = resolveApplicationURL() else {
#if DEBUG
            cmuxDebugLog(
                "foreignWindow.appMissing id=\(identifier) "
                    + "bundle=\(launchConfiguration.bundleIdentifier)"
            )
#endif
            return
        }
        guard prepareLaunchDirectories() else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.arguments = launchConfiguration.arguments
        if !launchConfiguration.environment.isEmpty {
            configuration.environment = launchConfiguration.environment
        }

        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            do {
                let application = try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                guard !Task.isCancelled, !self.isInvalidated else {
                    application.terminate()
                    return
                }
                self.runningApplication = application
                // Launched with `hides = true`.
                self.didRequestHide = true
                self.lastAppliedFrame = nil
                self.pendingRaise = true
                self.pendingActivate = self.shouldBeFocused
                self.scheduleApply()
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "foreignWindow.launchFailed id=\(self.identifier) "
                        + "bundle=\(self.launchConfiguration.bundleIdentifier) "
                        + "error=\(error.localizedDescription)"
                )
#endif
            }
        }
    }

    private func handleApplicationTerminated() {
#if DEBUG
        cmuxDebugLog("foreignWindow.appTerminated id=\(identifier)")
#endif
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil
        runningApplication = nil
        lastAppliedFrame = nil
        isHiddenForYield = false
        didRequestHide = false
    }

    private func resolveApplicationURL() -> URL? {
        let fileManager = FileManager.default
        if let preferredApplicationURL = launchConfiguration.preferredApplicationURL,
           fileManager.fileExists(atPath: preferredApplicationURL.path) {
            return preferredApplicationURL
        }

        if let installedURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: launchConfiguration.bundleIdentifier
        ) {
            return installedURL
        }

        return launchConfiguration.fallbackApplicationURLs.first {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    private func prepareLaunchDirectories() -> Bool {
        for directoryURL in launchConfiguration.directoriesToCreate {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "foreignWindow.directoryCreateFailed id=\(identifier) "
                        + "path=\(directoryURL.path) error=\(error.localizedDescription)"
                )
#endif
                return false
            }
        }
        return true
    }

    // MARK: Accessibility binding

    private func ensureAccessibilityBinding() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        if !isAccessibilityTrusted {
            let shouldPrompt = !accessibilityPromptRequested
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt
            ] as CFDictionary
            accessibilityPromptRequested = true
            isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
            guard isAccessibilityTrusted else { return }
        }

        if applicationElement == nil {
            applicationElement = AXUIElementCreateApplication(
                runningApplication.processIdentifier
            )
        }

        installAccessibilityObserverIfNeeded()
        if externalWindow == nil {
            _ = refreshExternalWindow()
        }
    }

    private func installAccessibilityObserverIfNeeded() {
        guard accessibilityObserver == nil,
              let applicationElement,
              let runningApplication else {
            return
        }

        var observer: AXObserver?
        let createResult = AXObserverCreate(
            runningApplication.processIdentifier,
            foreignWindowAXObserverCallback,
            &observer
        )
        guard createResult == .success, let observer else {
#if DEBUG
            cmuxDebugLog(
                "foreignWindow.axObserverCreateFailed id=\(identifier) "
                    + "code=\(createResult.rawValue)"
            )
#endif
            return
        }

        let refcon = Unmanaged.passRetained(self)
        let notificationResult = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXWindowCreatedNotification as CFString,
            refcon.toOpaque()
        )
        guard notificationResult == .success
                || notificationResult == .notificationAlreadyRegistered else {
            refcon.release()
#if DEBUG
            cmuxDebugLog(
                "foreignWindow.axObserverAddFailed id=\(identifier) "
                    + "code=\(notificationResult.rawValue)"
            )
#endif
            return
        }

        accessibilityObserver = observer
        observerRefcon = refcon
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAccessibilityObserver() {
        guard let accessibilityObserver else { return }
        unregisterWindowNotifications()
        if let applicationElement {
            _ = AXObserverRemoveNotification(
                accessibilityObserver,
                applicationElement,
                kAXWindowCreatedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(accessibilityObserver),
            .commonModes
        )
        self.accessibilityObserver = nil
        // Balance the +1 taken at install only after the source is gone.
        observerRefcon?.release()
        observerRefcon = nil
    }

    private func registerWindowNotifications(_ window: AXUIElement) {
        if let observedWindow, CFEqual(observedWindow, window) { return }
        unregisterWindowNotifications()
        guard let accessibilityObserver, let observerRefcon else { return }
        for name in Self.windowNotificationNames {
            let result = AXObserverAddNotification(
                accessibilityObserver,
                window,
                name as CFString,
                observerRefcon.toOpaque()
            )
#if DEBUG
            if result != .success, result != .notificationAlreadyRegistered {
                cmuxDebugLog(
                    "foreignWindow.axWindowObserveFailed id=\(identifier) "
                        + "name=\(name) code=\(result.rawValue)"
                )
            }
#else
            _ = result
#endif
        }
        observedWindow = window
    }

    private func unregisterWindowNotifications() {
        guard let observedWindow else { return }
        if let accessibilityObserver {
            for name in Self.windowNotificationNames {
                _ = AXObserverRemoveNotification(
                    accessibilityObserver,
                    observedWindow,
                    name as CFString
                )
            }
        }
        self.observedWindow = nil
    }

    @discardableResult
    private func refreshExternalWindow() -> Bool {
        guard let applicationElement,
              let preferredWindow = preferredExternalWindow(applicationElement) else {
            return false
        }
        if let externalWindow, CFEqual(externalWindow, preferredWindow) {
            registerWindowNotifications(preferredWindow)
            return true
        }
        externalWindow = preferredWindow
        lastAppliedFrame = nil
        registerWindowNotifications(preferredWindow)
        return true
    }

    private func preferredExternalWindow(
        _ applicationElement: AXUIElement
    ) -> AXUIElement? {
        let windows = axWindows(applicationElement)
        let standardWindows = windows.filter {
            axString($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
        return (standardWindows.isEmpty ? windows : standardWindows)
            .max { lhs, rhs in
                let lhsSize = axSize(lhs)
                let rhsSize = axSize(rhs)
                return lhsSize.width * lhsSize.height
                    < rhsSize.width * rhsSize.height
            }
    }

    // MARK: Presentation

    private func applyPresentation() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        guard shouldBeVisible, !isYielding else {
            if shouldBeVisible {
                isHiddenForYield = true
            }
            hideApplication(runningApplication)
            return
        }

        guard let targetFrame else { return }
        if externalWindow == nil {
            _ = refreshExternalWindow()
        }
        guard let window = externalWindow else { return }
        // Consume raise/activate only once there is a window to act on; the
        // window-created notification re-requests them otherwise.
        let activate = pendingActivate
        let raise = pendingRaise
        pendingActivate = false
        pendingRaise = false

        if lastAppliedFrame != targetFrame {
            if setExternalWindowFrame(targetFrame, window: window) {
                lastAppliedFrame = targetFrame
            } else {
                // The window may have been replaced; rebind and retry once.
                unregisterWindowNotifications()
                externalWindow = nil
                guard refreshExternalWindow(),
                      let replacementWindow = externalWindow,
                      setExternalWindowFrame(targetFrame, window: replacementWindow) else {
                    return
                }
                lastAppliedFrame = targetFrame
            }
        }

        guard let boundWindow = externalWindow else { return }
        if raise {
            _ = AXUIElementSetAttributeValue(
                boundWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        if didRequestHide || runningApplication.isHidden {
            _ = runningApplication.unhide()
            didRequestHide = false
        }
        isHiddenForYield = false
        if raise {
            _ = AXUIElementPerformAction(boundWindow, kAXRaiseAction as CFString)
        }
        if activate && shouldBeFocused {
            _ = runningApplication.activate(options: [.activateAllWindows])
            _ = AXUIElementPerformAction(boundWindow, kAXRaiseAction as CFString)
        }
    }

    private func hideApplication(_ runningApplication: NSRunningApplication) {
        if !runningApplication.isHidden {
            _ = runningApplication.hide()
        }
        didRequestHide = true
    }

    /// Re-applies the target rect when the external window moved or resized
    /// itself. Our own writes also produce these notifications; by the time
    /// they arrive the window already sits at the rect we wrote, so they fall
    /// through the equality check instead of looping.
    private func snapBackIfDisplaced() {
        guard shouldBeVisible,
              !isYielding,
              let targetFrame,
              lastAppliedFrame == targetFrame,
              let window = externalWindow,
              let currentFrame = axFrame(window) else {
            return
        }
        guard !Self.frame(currentFrame, approximatelyEquals: targetFrame) else {
            return
        }
        guard correctionsForTarget < Self.maximumCorrectionsPerTarget else { return }
        correctionsForTarget += 1
#if DEBUG
        cmuxDebugLog(
            "foreignWindow.snapBack id=\(identifier) attempt=\(correctionsForTarget) "
                + "current=\(currentFrame) target=\(targetFrame)"
        )
#endif
        lastAppliedFrame = nil
        scheduleApply()
    }

    private static func frame(
        _ lhs: CGRect,
        approximatelyEquals rhs: CGRect
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.width - rhs.width) <= frameTolerance
            && abs(lhs.height - rhs.height) <= frameTolerance
    }

    private func setExternalWindowFrame(
        _ frame: CGRect,
        window: AXUIElement
    ) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        return positionResult == .success && sizeResult == .success
    }

    // MARK: AX reads

    private func copiedAXValue(
        _ element: AXUIElement,
        attribute: String
    ) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value
    }

    private func axWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        guard let values = copiedAXValue(
            applicationElement,
            attribute: kAXWindowsAttribute
        ) as? [AnyObject] else {
            return []
        }
        return values.compactMap {
            unsafeBitCast($0, to: AXUIElement?.self)
        }
    }

    private func axString(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        copiedAXValue(element, attribute: attribute) as? String
    }

    private func axSize(_ element: AXUIElement) -> CGSize {
        guard let value = copiedAXValue(
            element,
            attribute: kAXSizeAttribute
        ) else {
            return .zero
        }
        var size = CGSize.zero
        AXValueGetValue(
            unsafeBitCast(value, to: AXValue.self),
            .cgSize,
            &size
        )
        return size
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copiedAXValue(
            element,
            attribute: kAXPositionAttribute
        ), let sizeValue = copiedAXValue(
            element,
            attribute: kAXSizeAttribute
        ) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeBitCast(positionValue, to: AXValue.self),
            .cgPoint,
            &position
        ), AXValueGetValue(
            unsafeBitCast(sizeValue, to: AXValue.self),
            .cgSize,
            &size
        ) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}
