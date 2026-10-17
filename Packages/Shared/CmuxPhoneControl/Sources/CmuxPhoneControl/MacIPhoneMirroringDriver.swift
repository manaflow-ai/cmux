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

        public init(
            deviceID: String = "iphone-mirroring",
            name: String = "Mirrored iPhone",
            model: String = "iPhone",
            osVersion: String = "unknown"
        ) {
            self.deviceID = deviceID
            self.name = name
            self.model = model
            self.osVersion = osVersion
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
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(Int(window.frame.width), 1)
        configuration.height = max(Int(window.frame.height), 1)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let data = pngData(image) else {
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
            postMouse(.leftMouseDown, at: screenPoint(point, in: window, geometry: geometry), to: processID)
            postMouse(.leftMouseUp, at: screenPoint(point, in: window, geometry: geometry), to: processID)
        case .swipe:
            guard let start = action.point, let end = action.endPoint else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
            let startPoint = screenPoint(start, in: window, geometry: geometry)
            let endPoint = screenPoint(end, in: window, geometry: geometry)
            postMouse(.leftMouseDown, at: startPoint, to: processID)
            let steps = max(action.durationMilliseconds ?? 250, 1) / 16
            for step in 1...max(steps, 1) {
                let fraction = Double(step) / Double(max(steps, 1))
                postMouse(
                    .leftMouseDragged,
                    at: CGPoint(
                        x: startPoint.x + ((endPoint.x - startPoint.x) * fraction),
                        y: startPoint.y + ((endPoint.y - startPoint.y) * fraction)
                    ),
                    to: processID
                )
            }
            postMouse(.leftMouseUp, at: endPoint, to: processID)
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
        let candidate = content.windows.first { window in
            let application = window.owningApplication
            return application?.bundleIdentifier == "com.apple.ScreenContinuity"
                || application?.applicationName.localizedCaseInsensitiveContains("iPhone Mirroring") == true
        }
        guard let candidate else {
            throw PhoneDriverError.unavailable(
                "iPhone Mirroring window not found; unlock and pair the phone first"
            )
        }
        window = candidate
        return candidate
    }

    private func geometry(for window: SCWindow) -> PhoneDisplayGeometry {
        PhoneDisplayGeometry(
            width: max(Int(window.frame.width), 1),
            height: max(Int(window.frame.height), 1),
            scale: 1,
            orientation: window.frame.height >= window.frame.width ? .portrait : .landscapeLeft
        )
    }

    private func screenPoint(
        _ point: PhonePoint,
        in window: SCWindow,
        geometry: PhoneDisplayGeometry
    ) -> CGPoint {
        let x = window.frame.minX + (point.x * Double(geometry.width))
        // Quartz uses a top-left screen origin for mouse events generated from
        // window coordinates, matching ScreenCaptureKit's frame orientation.
        let y = window.frame.minY + (point.y * Double(geometry.height))
        return CGPoint(x: x, y: y)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, to processID: pid_t) {
        let button: CGMouseButton = .left
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )
        event?.postToPid(processID)
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
