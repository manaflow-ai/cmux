import AppKit
import ApplicationServices
import Foundation

// AXObserver requires a C callback; this trampoline only forwards to the
// main-actor session that owns the external process and its window.
private func foreignWindowAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    _ = observer
    _ = element
    _ = notification
    guard let refcon else { return }
    let session = Unmanaged<ForeignWindowSession>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        session.handleAccessibilityWindowCreated()
    }
}

@MainActor
final class ForeignWindowSession {
    private let surfaceID: UUID
    private let launchConfiguration: ForeignWindowLaunchConfiguration
    private var launchTask: Task<Void, Never>?
    private var hasAttemptedLaunch = false
    private var isInvalidated = false
    private var runningApplication: NSRunningApplication?
    private var applicationElement: AXUIElement?
    private var externalWindow: AXUIElement?
    private var accessibilityObserver: AXObserver?
    private var accessibilityPromptRequested = false
    private var targetFrame: CGRect?
    private var shouldBeVisible = false
    private var shouldBeFocused = false

    init(
        surfaceID: UUID,
        launchConfiguration: ForeignWindowLaunchConfiguration
    ) {
        self.surfaceID = surfaceID
        self.launchConfiguration = launchConfiguration
    }

    func startIfNeeded() {
        guard !isInvalidated,
              !hasAttemptedLaunch,
              launchTask == nil,
              runningApplication == nil else {
            if runningApplication != nil {
                ensureAccessibilityBinding()
            }
            return
        }
        hasAttemptedLaunch = true

        guard let applicationURL = resolveApplicationURL() else {
#if DEBUG
            cmuxDebugLog(
                "foreignWindow.appMissing surface=\(surfaceID.uuidString) "
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
                self.ensureAccessibilityBinding()
                self.applyPresentation(
                    activateIfFocused: self.shouldBeFocused,
                    raiseWindow: true
                )
            } catch {
#if DEBUG
                cmuxDebugLog(
                    "foreignWindow.launchFailed surface=\(self.surfaceID.uuidString) "
                        + "bundle=\(self.launchConfiguration.bundleIdentifier) "
                        + "error=\(error.localizedDescription)"
                )
#endif
            }
        }
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
        self.targetFrame = targetFrame
        shouldBeVisible = isVisible
        shouldBeFocused = isFocused

        if runningApplication == nil {
            startIfNeeded()
            return
        }

        ensureAccessibilityBinding()
        applyPresentation(
            activateIfFocused: becameFocused,
            raiseWindow: raiseWindow || becameVisible
        )
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        launchTask?.cancel()
        launchTask = nil
        removeAccessibilityObserver()
        externalWindow = nil
        applicationElement = nil

        if let runningApplication, !runningApplication.isTerminated {
            runningApplication.terminate()
        }
        self.runningApplication = nil
    }

    func handleAccessibilityWindowCreated() {
        guard !isInvalidated, refreshExternalWindow() else { return }
        applyPresentation(
            activateIfFocused: shouldBeFocused,
            raiseWindow: true
        )
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
                    "foreignWindow.directoryCreateFailed surface=\(surfaceID.uuidString) "
                        + "path=\(directoryURL.path) error=\(error.localizedDescription)"
                )
#endif
                return false
            }
        }
        return true
    }

    private func ensureAccessibilityBinding() {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        let shouldPrompt = !accessibilityPromptRequested
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt
        ] as CFDictionary
        accessibilityPromptRequested = true
        guard AXIsProcessTrustedWithOptions(options) else { return }

        if applicationElement == nil {
            applicationElement = AXUIElementCreateApplication(
                runningApplication.processIdentifier
            )
        }

        installAccessibilityObserverIfNeeded()
        _ = refreshExternalWindow()
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
                "foreignWindow.axObserverCreateFailed surface=\(surfaceID.uuidString) "
                    + "code=\(createResult.rawValue)"
            )
#endif
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notificationResult = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXWindowCreatedNotification as CFString,
            refcon
        )
        guard notificationResult == .success
                || notificationResult == .notificationAlreadyRegistered else {
#if DEBUG
            cmuxDebugLog(
                "foreignWindow.axObserverAddFailed surface=\(surfaceID.uuidString) "
                    + "code=\(notificationResult.rawValue)"
            )
#endif
            return
        }

        accessibilityObserver = observer
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func removeAccessibilityObserver() {
        guard let accessibilityObserver else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(accessibilityObserver),
            .commonModes
        )
        self.accessibilityObserver = nil
    }

    @discardableResult
    private func refreshExternalWindow() -> Bool {
        guard let applicationElement,
              let preferredWindow = preferredExternalWindow(applicationElement) else {
            return false
        }
        externalWindow = preferredWindow
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

    private func applyPresentation(
        activateIfFocused: Bool,
        raiseWindow: Bool
    ) {
        guard let runningApplication, !runningApplication.isTerminated else { return }

        guard shouldBeVisible else {
            if !runningApplication.isHidden {
                _ = runningApplication.hide()
            }
            return
        }

        guard let targetFrame else { return }
        if externalWindow == nil {
            _ = refreshExternalWindow()
        }
        guard let externalWindow else { return }

        if !setExternalWindowFrame(targetFrame, window: externalWindow) {
            self.externalWindow = nil
            guard refreshExternalWindow(),
                  let replacementWindow = self.externalWindow else {
                return
            }
            _ = setExternalWindowFrame(targetFrame, window: replacementWindow)
        }

        _ = AXUIElementSetAttributeValue(
            self.externalWindow ?? externalWindow,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        if runningApplication.isHidden {
            _ = runningApplication.unhide()
        }
        if raiseWindow, let window = self.externalWindow {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if activateIfFocused && shouldBeFocused {
            _ = runningApplication.activate(options: [.activateAllWindows])
            if let window = self.externalWindow {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
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
}
