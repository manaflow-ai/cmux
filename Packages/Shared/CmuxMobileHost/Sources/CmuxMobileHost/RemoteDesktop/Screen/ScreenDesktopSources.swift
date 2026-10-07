#if os(macOS)
public import CmuxRemoteDesktop
public import CoreGraphics
import Foundation
import ScreenCaptureKit

/// This Mac's displays and windows through ScreenCaptureKit, plus VNC
/// servers through `vnc`. The app passes its pasteboard and display names
/// (NSScreen.localizedName); this package has no AppKit.
public struct ScreenDesktopSources: RemoteDesktopSources {
    public let pasteboard: any RemoteDesktopPasteboard
    public let vnc: VncDesktopConnector
    public let displayName: @Sendable (CGDirectDisplayID) -> String?

    public init(pasteboard: any RemoteDesktopPasteboard,
                vnc: VncDesktopConnector = VncDesktopConnector(dial: { try await NWRfbTransport.connect(to: $0) }),
                displayName: @escaping @Sendable (CGDirectDisplayID) -> String? = { _ in nil }) {
        self.pasteboard = pasteboard
        self.vnc = vnc
        self.displayName = displayName
    }

    public func displays() async -> [DesktopDisplay] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let main = CGMainDisplayID()
        return content.displays.map { display in
            let (width, height, scale) = Self.pixels(display.displayID)
            return DesktopDisplay(id: display.displayID, name: name(display.displayID), width: width, height: height, scale: scale,
                                  isMain: display.displayID == main)
        }
    }

    public func windows() async -> [DesktopWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 64 && $0.frame.height >= 64 }
            .filter { $0.owningApplication.map { $0.processID != own } ?? false }
            .map { DesktopWindow(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "") }
    }

    public func describe(_ target: DesktopTarget) async throws -> DesktopTargetInfo {
        switch target {
        case .display(let id):
            let displays = await displays()
            guard let display = id.map({ id in displays.first { $0.id == id } }) ?? displays.first(where: \.isMain) else {
                throw RemoteDesktopSourceError.displayNotFound
            }
            return DesktopTargetInfo(kind: .display, width: display.width, height: display.height, scale: display.scale,
                                     name: display.name)
        case .window(let id):
            let window = try await window(id)
            let scale = Self.scale(at: CGPoint(x: window.frame.midX, y: window.frame.midY))
            return DesktopTargetInfo(kind: .window, width: Int(window.frame.width * scale), height: Int(window.frame.height * scale),
                                     scale: scale, name: window.title ?? window.owningApplication?.applicationName ?? "")
        case .vnc:
            return try await vnc.describe(target)
        }
    }

    public func open(_ request: RemoteDesktopOpenRequest) async throws -> any RemoteDesktopTarget {
        let info = try await describe(request.target)
        switch request.target {
        case .display(let id):
            let displayID = id ?? CGMainDisplayID()
            let bounds = CGDisplayBounds(displayID)
            let capture = DisplayFrameCapture(displayID: displayID, sourceRect: Self.points(request.region, scale: info.scale))
            return ScreenDesktopTarget(info: info, capture: .display(capture), origin: bounds.origin, bounds: bounds,
                                       pasteboard: pasteboard)
        case .window(let id):
            let window = try await window(id)
            let capture = ScreenCaptureFrameCapture(windowID: id, contentRect: Self.points(request.region, scale: info.scale))
            return ScreenDesktopTarget(info: info, capture: .window(capture), origin: window.frame.origin, bounds: window.frame,
                                       pasteboard: pasteboard)
        case .vnc:
            return try await vnc.open(request)
        }
    }

    private func window(_ id: UInt32) async throws -> SCWindow {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }) else {
            throw RemoteDesktopSourceError.windowNotFound
        }
        return window
    }

    private func name(_ id: CGDirectDisplayID) -> String {
        displayName(id) ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)")
    }

    private static func pixels(_ id: CGDirectDisplayID) -> (Int, Int, Double) {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else {
            let bounds = CGDisplayBounds(id)
            return (Int(bounds.width), Int(bounds.height), 1)
        }
        return (mode.pixelWidth, mode.pixelHeight, Double(mode.pixelWidth) / Double(mode.width))
    }

    private static func scale(at point: CGPoint) -> Double {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return 1 }
        return pixels(display).2
    }

    private static func points(_ rect: DesktopRect, scale: Double) -> CGRect {
        let scale = max(scale, 0.1)
        return CGRect(x: Double(rect.x) / scale, y: Double(rect.y) / scale, width: Double(rect.width) / scale,
                      height: Double(rect.height) / scale)
    }
}
#endif
