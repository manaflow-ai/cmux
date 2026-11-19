import AppKit
import CoreText
import Darwin
import Metal
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

    /// The system Apple menu fills on the first key-equivalent walk of a launch (the first Control chord, R-INPUT
    /// first-key menu stall). Its device image of "About This Mac" makes UTType's lookup of this Mac's model
    /// (MobileGestalt, an IOKit call), once per process. The Computer image and the model's UTType make the same lookup
    /// here first; the menu keeps every item and image it shows (#35916 has the A/B).
    public nonisolated func appleMenuDevice() {
        _ = NSImage(named: NSImage.computerName)?.bestRepresentation(for: NSRect(x: 0, y: 0, width: 16, height: 16), context: nil, hints: nil)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return }
        let code = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        _ = UTType(tag: code, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
    }

    /// Starts ``metal()`` and ``coreText()``, each on its own named thread (threading-model.md, "Launch and misc"):
    /// one call each, a few ms, then the thread ends.
    public nonisolated func startGraphics() {
        let steps: [(String, @Sendable () -> Void)] = [
            ("cmux-next metal warm-up", { self.metal() }), ("cmux-next coretext warm-up", { self.coreText() }),
        ]
        for (label, work) in steps {
            let thread = Thread(block: work)
            thread.name = label
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// The first Metal device and command queue of a process pay the framework's and the driver's one-time setup,
    /// on the main thread where the launch makes the living wallpapers' renderer (`BackdropImageStore.shared`,
    /// `BackdropShaderRenderer`) before the first window. Made and dropped here first (Ghostty PR 13722 did the same
    /// for its renderer: first frame 126 -> 92 ms together with the CoreText step below).
    public nonisolated func metal() {
        _ = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    }

    /// The first CoreText lookup of a process loads the system font registry; later lookups take microseconds. The
    /// first window's text (the system UI font) and the terminal's emoji fallback (Apple Color Emoji) would
    /// otherwise pay it on the main thread.
    public nonisolated func coreText() {
        _ = CTFontCreateUIFontForLanguage(.system, 0, nil)
        _ = CTFontCreateWithName("AppleColorEmoji" as CFString, 0, nil)
    }
}
