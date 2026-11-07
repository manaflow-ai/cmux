#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Host-side source for macOS iPhone Mirroring. The mirrored phone remains a
/// user-controlled window: ScreenCaptureKit captures that window, while
/// target-PID Quartz events provide coordinate input without activating the
/// user's frontmost application. The remote accessibility tree is not exposed
/// by the host window, so this source reports that capability as unavailable.
public actor MacIPhoneMirroringDriver: PhoneDriver {
    public struct Configuration: Sendable {
        public let deviceID: String
        public let name: String
        public let model: String
        public let osVersion: String
        /// Optional exact window title used to select one of several mirrored phones.
        public let windowTitle: String?
        /// Insets, in window points, around the actual mirrored phone surface.
        /// iPhone Mirroring includes host window chrome; callers should provide
        /// the measured content insets when the window is decorated.
        public let contentInsets: PhoneDisplayGeometry.Insets

        public init(
            deviceID: String = "iphone-mirroring",
            name: String = "Mirrored iPhone",
            model: String = "iPhone",
            osVersion: String = "unknown",
            contentInsets: PhoneDisplayGeometry.Insets = .zero,
            windowTitle: String? = nil
        ) {
            self.deviceID = deviceID
            self.name = name
            self.model = model
            self.osVersion = osVersion
            self.contentInsets = contentInsets
            self.windowTitle = windowTitle
        }
    }

    private let configuration: Configuration
    private var window: SCWindow?
    private var sequence: UInt64 = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func device() async throws -> PhoneDevice {
        let window = try await mirroredWindow()
        let geometry = geometry(for: window)
        return PhoneDevice(
            id: configuration.deviceID,
            name: configuration.name,
            model: configuration.model,
            osVersion: configuration.osVersion,
            source: .iphoneMirroring,
            state: .available,
            geometry: geometry,
            capabilities: .init(
                screenSnapshot: true,
                screenStream: false,
                accessibilityTree: false,
                tap: true,
                swipe: true,
                typing: false,
                physicalButtons: false
            )
        )
    }

    public func snapshot() async throws -> PhoneScreenFrame {
        let window = try await mirroredWindow()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let fullWidth = max(Int(window.frame.width.rounded()), 1)
        let fullHeight = max(Int(window.frame.height.rounded()), 1)
        configuration.width = fullWidth
        configuration.height = fullHeight
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let content = contentFrame(for: window)
        guard let cropped = crop(image, to: content, in: window.frame),
              let data = pngData(cropped) else {
            throw PhoneDriverError.malformedResponse("ScreenCaptureKit returned an unencodable image")
        }
        sequence += 1
        let geometry = geometry(for: window)
        return PhoneScreenFrame(
            sequence: sequence,
            width: geometry.width,
            height: geometry.height,
            orientation: geometry.orientation,
            data: data
        )
    }

    public func accessibilityTree() async throws -> PhoneUIElement? {
        // The host AX tree describes the mirroring window, not the remote
        // phone's controls. Returning nil keeps callers from mistaking it for
        // semantic phone UI and lets them fall back to coordinates or OCR.
        nil
    }

    public func perform(_ action: PhoneActionRequest) async throws -> PhoneActionReceipt {
        try Task.checkCancellation()
        try action.validated()
        guard AXIsProcessTrusted() else {
            throw PhoneError(
                code: "permission_denied",
                message: "enable Accessibility permission for cmux to send mirrored-window input"
            )
        }
        let window = try await mirroredWindow()
        let geometry = geometry(for: window)
        guard let processID = window.owningApplication?.processID else {
            throw PhoneDriverError.unavailable("mirroring window has no owning process")
        }
        switch action.kind {
        case .tap:
            guard let point = action.point else {
                throw PhoneError(code: "invalid_action", message: "tap requires point")
            }
            try postMouse(.leftMouseDown, at: screenPoint(point, in: window, geometry: geometry), to: processID)
            try postMouse(.leftMouseUp, at: screenPoint(point, in: window, geometry: geometry), to: processID)
        case .swipe:
            guard let start = action.point, let end = action.endPoint else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
            let startPoint = screenPoint(start, in: window, geometry: geometry)
            let endPoint = screenPoint(end, in: window, geometry: geometry)
            try postMouse(.leftMouseDown, at: startPoint, to: processID)
            let steps = max(action.durationMilliseconds ?? 250, 1) / 16
            for step in 1...max(steps, 1) {
                try Task.checkCancellation()
                let fraction = Double(step) / Double(max(steps, 1))
                try postMouse(
                    .leftMouseDragged,
                    at: CGPoint(
                        x: startPoint.x + ((endPoint.x - startPoint.x) * fraction),
                        y: startPoint.y + ((endPoint.y - startPoint.y) * fraction)
                    ),
                    to: processID
                )
                if step < max(steps, 1) {
                    try await Task.sleep(nanoseconds: 16_000_000)
                }
            }
            try postMouse(.leftMouseUp, at: endPoint, to: processID)
        case .longPress, .type, .press:
            throw PhoneDriverError.unsupported("\(action.kind.rawValue) is unavailable for host mirroring")
        }
        sequence += 1
        return PhoneActionReceipt(
            actionID: action.actionID,
            accepted: true,
            screenSequence: sequence,
            detail: "mirrored-window event posted to target process"
        )
    }

    private func mirroredWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter { window in
            let application = window.owningApplication
            return application?.bundleIdentifier == "com.apple.ScreenContinuity"
                || application?.applicationName.localizedCaseInsensitiveContains("iPhone Mirroring") == true
        }
        let candidate = if let windowTitle = configuration.windowTitle {
            candidates.first { $0.title == windowTitle }
        } else {
            candidates.first
        }
        guard let candidate else {
            throw PhoneDriverError.unavailable(
                "iPhone Mirroring window not found; unlock and pair the phone first"
            )
        }
        window = candidate
        return candidate
    }

    private func contentFrame(for window: SCWindow) -> CGRect {
        let frame = window.frame.standardized
        let insets = configuration.contentInsets
        let width = max(frame.width - insets.left - insets.right, 1)
        let height = max(frame.height - insets.top - insets.bottom, 1)
        return CGRect(
            x: frame.minX + insets.left,
            y: frame.minY + insets.top,
            width: width,
            height: height
        )
    }

    private func geometry(for window: SCWindow) -> PhoneDisplayGeometry {
        let content = contentFrame(for: window)
        return PhoneDisplayGeometry(
            width: max(Int(content.width.rounded()), 1),
            height: max(Int(content.height.rounded()), 1),
            scale: 1,
            orientation: content.height >= content.width ? .portrait : .landscapeLeft
        )
    }

    private func screenPoint(
        _ point: PhonePoint,
        in window: SCWindow,
        geometry: PhoneDisplayGeometry
    ) -> CGPoint {
        let content = contentFrame(for: window)
        let x = content.minX + (point.x * content.width)
        // Quartz uses a top-left screen origin for target-process mouse events.
        let y = content.minY + (point.y * content.height)
        return CGPoint(x: x, y: y)
    }

    private func crop(_ image: CGImage, to content: CGRect, in window: CGRect) -> CGImage? {
        let scaleX = CGFloat(image.width) / max(window.width, 1)
        let scaleY = CGFloat(image.height) / max(window.height, 1)
        let x = max(Int((content.minX - window.minX) * scaleX), 0)
        let yFromTop = max(Int((content.maxY - window.minY) * scaleY), 0)
        let width = min(Int(content.width * scaleX), image.width - x)
        let height = min(Int(content.height * scaleY), image.height - yFromTop)
        guard width > 0, height > 0 else { return nil }
        // CGImage crop rectangles are bottom-left based; ScreenCaptureKit
        // frames are described in top-left window coordinates.
        let y = image.height - yFromTop - height
        return image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, to processID: pid_t) throws {
        let button: CGMouseButton = .left
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw PhoneDriverError.unavailable("could not create mirrored-window input event")
        }
        event.postToPid(processID)
    }

    private func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
