public import AppKit
import Darwin
import UniformTypeIdentifiers

/// System work that runs on the main thread the first time the app needs it, done first on the launch's
/// background thread (`LaunchWarmup`), so the main thread finds it cached. Each step is a public API call that is
/// safe off the main thread and changes nothing the person sees.
public nonisolated struct LaunchSystemWarmup: Sendable {
    public init() {}

    /// The display UUID lookup loads ColorSync's display services on first use: 60-90 ms on the main thread while the
    /// first window was placed (`WindowPlacementFallback.displayID`).
    public nonisolated func displays() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return }
        for display in displays.prefix(Int(count)) { _ = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() }
    }

    /// The system Apple menu fills on the first key-equivalent walk of a launch (the first Control chord: 13-38 ms on the
    /// main thread, R-INPUT first-key menu stall). Most of that is the device image of "About This Mac": UTType's lookup
    /// of this Mac's model (MobileGestalt, an IOKit call), made once per process. The Computer image and the model's
    /// UTType make the same lookup here first; the menu keeps every item and image it shows.
    public nonisolated func appleMenuDevice() {
        _ = NSImage(named: NSImage.computerName)?.bestRepresentation(for: NSRect(x: 0, y: 0, width: 16, height: 16), context: nil, hints: nil)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return }
        _ = UTType(tag: String(cString: model), tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
    }
}
