import AppKit
import ApplicationServices

enum WindowPlacement: CaseIterable {
    case center
    case leftHalf
    case rightHalf
    case fill
}

enum AccessibilityActionResult: Equatable {
    case succeeded
    case accessibilityPermissionMissing
    case windowUnavailable
    case failed(AXError)
}

@MainActor
struct AccessibilityWindowController {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func raise(_ window: HostWindow) -> AccessibilityActionResult {
        guard isTrusted else {
            return .accessibilityPermissionMissing
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        guard let axWindow = resolveAXWindow(for: window, app: app) else {
            return .windowUnavailable
        }

        let frontmostResult = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard frontmostResult == .success else {
            return .failed(frontmostResult)
        }

        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        return raiseResult == .success ? .succeeded : .failed(raiseResult)
    }

    func place(_ window: HostWindow, placement: WindowPlacement) -> AccessibilityActionResult {
        guard isTrusted else {
            return .accessibilityPermissionMissing
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        guard let axWindow = resolveAXWindow(for: window, app: app) else {
            return .windowUnavailable
        }

        let targetFrame = targetFrame(for: window, placement: placement)
        let sizeResult = setSize(targetFrame.size, on: axWindow)
        guard sizeResult == .success else {
            return .failed(sizeResult)
        }

        let positionResult = setPosition(targetFrame.origin, on: axWindow)
        guard positionResult == .success else {
            return .failed(positionResult)
        }

        _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        return .succeeded
    }

    func place(_ window: HostWindow, frame targetFrame: CGRect, raise: Bool) -> AccessibilityActionResult {
        guard isTrusted else {
            return .accessibilityPermissionMissing
        }

        let app = AXUIElementCreateApplication(window.ownerPID)
        guard let axWindow = resolveAXWindow(for: window, app: app) else {
            return .windowUnavailable
        }

        let integralFrame = targetFrame.integral
        let currentFrame = readFrame(from: axWindow)

        if currentFrame?.size.isApproximatelyEqual(to: integralFrame.size) != true {
            let sizeResult = setSize(integralFrame.size, on: axWindow)
            guard sizeResult == .success else {
                return .failed(sizeResult)
            }
        }

        if currentFrame?.origin.isApproximatelyEqual(to: integralFrame.origin) != true {
            let positionResult = setPosition(integralFrame.origin, on: axWindow)
            guard positionResult == .success else {
                return .failed(positionResult)
            }
        }

        if raise {
            _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }

        return .succeeded
    }

    func resolvedWindow(for window: HostWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.ownerPID)
        return resolveAXWindow(for: window, app: app)
    }

    func frame(of element: AXUIElement) -> CGRect? {
        readFrame(from: element)
    }

    private func resolveAXWindow(for window: HostWindow, app: AXUIElement) -> AXUIElement? {
        guard let axWindows = axWindows(for: app), !axWindows.isEmpty else {
            return nil
        }

        if window.hasTitle, let matchingTitle = axWindows.first(where: { readStringAttribute(kAXTitleAttribute, from: $0) == window.title }) {
            return matchingTitle
        }

        if let matchingFrame = axWindows.first(where: { candidate in
            guard let frame = readFrame(from: candidate) else {
                return false
            }
            return abs(frame.width - window.frame.width) < 8
                && abs(frame.height - window.frame.height) < 8
                && abs(frame.minX - window.frame.minX) < 12
                && abs(frame.minY - window.frame.minY) < 12
        }) {
            return matchingFrame
        }

        return axWindows.first
    }

    private func axWindows(for app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func readStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func readFrame(from element: AXUIElement) -> CGRect? {
        guard let position = readPointAttribute(kAXPositionAttribute, from: element),
              let size = readSizeAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func readPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func readSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func setPosition(_ position: CGPoint, on element: AXUIElement) -> AXError {
        var mutablePosition = position
        guard let value = AXValueCreate(.cgPoint, &mutablePosition) else {
            return .cannotComplete
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> AXError {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return .cannotComplete
        }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func targetFrame(for window: HostWindow, placement: WindowPlacement) -> CGRect {
        let visibleFrame = visibleDisplayFrame(containing: window)
        let gap: CGFloat = 10
        let insetFrame = visibleFrame.insetBy(dx: gap, dy: gap)

        switch placement {
        case .center:
            let width = min(max(820, insetFrame.width * 0.72), insetFrame.width)
            let height = min(max(560, insetFrame.height * 0.72), insetFrame.height)
            return CGRect(
                x: insetFrame.midX - width / 2,
                y: insetFrame.midY - height / 2,
                width: width,
                height: height
            ).integral
        case .leftHalf:
            return CGRect(
                x: insetFrame.minX,
                y: insetFrame.minY,
                width: (insetFrame.width - gap) / 2,
                height: insetFrame.height
            ).integral
        case .rightHalf:
            let width = (insetFrame.width - gap) / 2
            return CGRect(
                x: insetFrame.maxX - width,
                y: insetFrame.minY,
                width: width,
                height: insetFrame.height
            ).integral
        case .fill:
            return insetFrame.integral
        }
    }

    private func visibleDisplayFrame(containing window: HostWindow) -> CGRect {
        guard let screen = NSScreen.screens.max(by: { lhs, rhs in
            displayBounds(for: lhs).intersection(window.frame).area < displayBounds(for: rhs).intersection(window.frame).area
        }) else {
            return window.frame
        }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let displayFrame = displayBounds(for: screen)
        return CGRect(
            x: displayFrame.minX + (visibleFrame.minX - screenFrame.minX),
            y: displayFrame.minY + (screenFrame.maxY - visibleFrame.maxY),
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    private func displayBounds(for screen: NSScreen) -> CGRect {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return screen.frame
        }
        return CGDisplayBounds(CGDirectDisplayID(displayID.uint32Value))
    }
}

private extension CGPoint {
    func isApproximatelyEqual(to other: CGPoint) -> Bool {
        abs(x - other.x) < 1 && abs(y - other.y) < 1
    }
}

private extension CGSize {
    func isApproximatelyEqual(to other: CGSize) -> Bool {
        abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else {
            return 0
        }
        return width * height
    }
}
