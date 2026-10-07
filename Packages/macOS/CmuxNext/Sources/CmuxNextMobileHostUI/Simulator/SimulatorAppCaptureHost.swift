import AppKit
public import CmuxMobileHost
public import CmuxMobileWire
import ScreenCaptureKit

/// `SimulatorCaptureHost` over the Simulator app (c14-web.md 6): booted
/// devices from `xcrun simctl list devices -j`, pixels of the device's
/// Simulator window through ScreenCaptureKit, touches and keys as mouse and
/// key events posted to the Simulator process only (the user's pointer and
/// keyboard focus never move), the phone's clipboard through `simctl pbcopy`.
/// It uses no private SimulatorKit API; the window must be open on this Mac.
public struct SimulatorAppCaptureHost: SimulatorCaptureHost {
    static let bundleID = "com.apple.iphonesimulator"
    private let simctl = SimctlRunner()

    public init() {}

    public func simulators() async throws -> [SimulatorInfo] {
        let listed = try SimctlSimulatorList().parse(try await simctl.run(["list", "devices", "-j"]))
        return listed.sorted { ($0.state == .booted ? 0 : 1, $0.name) < ($1.state == .booted ? 0 : 1, $1.name) }
    }

    public func attach(_ request: SimulatorAttachRequest) async throws -> any SimulatorAttachment {
        let devices = try await simulators()
        guard let device = devices.first(where: { $0.udid == request.udid && $0.state == .booted }) else {
            throw SimulatorCaptureError.notFound
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw SimulatorCaptureError.unavailable("Screen Recording is not allowed for cmux")
        }
        guard let window = content.windows.first(where: { window in
            window.owningApplication?.bundleIdentifier == Self.bundleID && (window.title ?? "").contains(device.name)
        }), let pid = window.owningApplication?.processID else {
            throw SimulatorCaptureError.unavailable("open \(device.name) in Simulator on this Mac")
        }
        let geometry = SimulatorWindowGeometry(windowFrame: window.frame)
        return SimulatorAppAttachment(udid: device.udid, windowID: window.windowID, pid: pid, geometry: geometry,
                                      scale: Double(NSScreen.main?.backingScaleFactor ?? 2), simctl: simctl)
    }
}
