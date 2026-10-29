import CmuxNextSignposts
import CoreText
import Foundation
import Metal

/// The first terminal's costs that need no surface, paid on a launch thread while main reads the settings and
/// builds the config (feature `terminalLaunchPrefetch`), as Chrome starts the GPU process and
/// warms its font cache before the first tab asks (content/browser/gpu/gpu_process_host.cc,
/// skia/ext/font_utils.cc):
///
/// - The Metal device. `ghostty_app_new` picks its device on main (ghostty-next src/renderer/metal/Device.zig,
///   `chooseDevice`), and the process's first `MTLCopyAllDevices` loads the driver.
/// - The terminal's face, by the Ghostty config files' `font-family` (cmux.json's `terminal.fontFamily` is not read
///   yet; the first match still loads the font registry): the first `ghostty_surface_new` matches it on main
///   (ghostty-next src/font/discovery.zig, `discover`).
/// - Apple Color Emoji, which every font grid adds by name (src/font/SharedGridSet.zig).
/// - The fallback cascade of the face, which a codepoint the face lacks is looked up in (`discoverFallback`).
///
/// Thread safety: Core Text's functions are thread-safe and its fonts and descriptors immutable ("Core Text
/// Programming Guide", Overview: "All individual functions in Core Text are thread-safe"); `MTLCopyAllDevices` and
/// an `MTLDevice` may be used from any thread (Metal's device and command queue objects are thread-safe). Every
/// object made here stays on this thread and is released here; what the main thread then finds warm are the
/// framework's own process-wide caches (the driver, the font registry, the cascade lists). The config read takes
/// no lock: it reads files the config build reads too, and both only read.
///
/// The shaders need no prefetch here: libghostty loads a precompiled metallib (`newLibraryWithData`, shaders.zig)
/// and builds the pipelines on the renderer thread at its first draw, warmed by its own thread from
/// `ghostty_app_new`. Starting that warm-up before `ghostty_app_new` needs a libghostty export (a fork change).
public nonisolated struct TerminalLaunchPrefetch: Sendable {
    /// One Metal device's traits that pick it, as Ghostty picks (``preferredDevice(_:)``).
    nonisolated struct DeviceTraits: Equatable {
        var isHeadless: Bool
        var isRemovable: Bool
        var isLowPower: Bool
    }

    /// The point size the faces load at; Ghostty's discovery loads at 12 and resizes (discovery.zig).
    static let pointSize: CGFloat = 12

    /// The Ghostty config files whose `font-family` lines name the face, read on the prefetch thread.
    private let configFiles: @Sendable () -> [String]

    /// The app's prefetch: the face from `CMUX_NEXT_GHOSTTY_CONFIG`'s file when set, else from Ghostty's default
    /// config files (``GhosttyRuntime/defaultConfigCandidatePaths(homeDirectory:applicationSupportDirectory:environment:)``).
    public init() {
        self.init(configFiles: {
            let environment = ProcessInfo.processInfo.environment
            if let file = environment[GhosttyRuntime.configOverrideKey], !file.isEmpty { return [file] }
            return GhosttyRuntime.defaultConfigCandidatePaths(environment: environment)
        })
    }

    /// - Parameter configFiles: The config files whose `font-family` lines name the face (tests).
    init(configFiles: @escaping @Sendable () -> [String]) {
        self.configFiles = configFiles
    }

    /// Runs ``run()`` on a thread of its own, `cmux-next terminal prefetch`, at user-initiated: the first window's
    /// terminal waits on what it loads (threading-model.md, "Launch warm-ups"). The app calls it once, from `main`.
    public func start() {
        let thread = Thread { [self] in run() }
        thread.name = "cmux-next terminal prefetch"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Opens the Metal device and loads the fonts, inside the `launch.terminal_prefetch` signpost interval. It
    /// blocks (driver load, file reads, font maps): call it on a thread of its own, never on main.
    public func run() {
        LaunchSignposts().measure(.terminalPrefetch) {
            Self.openMetalDevice()
            Self.loadFonts(family: GhosttyConfigFontFamily.family(inFiles: configFiles()))
        }
    }

    /// The index of the device Ghostty renders on (Device.zig `chooseDevice`): the last one with a display before an
    /// eGPU or low-power one, which is taken at once; nil when every device is headless.
    static func preferredDevice(_ devices: [DeviceTraits]) -> Int? {
        var chosen: Int?
        for (index, device) in devices.enumerated() where !device.isHeadless {
            chosen = index
            if device.isRemovable || device.isLowPower { break }
        }
        return chosen
    }

    /// Loads the driver of the device Ghostty will pick and its first command queue's one-time setup.
    private static func openMetalDevice() {
        let devices = MTLCopyAllDevices()
        let traits = devices.map { DeviceTraits(isHeadless: $0.isHeadless, isRemovable: $0.isRemovable, isLowPower: $0.isLowPower) }
        guard let index = preferredDevice(traits) else { return }
        _ = devices[index].makeCommandQueue()
    }

    /// Loads the face named `family` (a system monospaced face when nil or not installed), Apple Color Emoji and the
    /// face's fallback cascade.
    private static func loadFonts(family: String?) {
        let face = family.flatMap { matchingFace(family: $0) }
            ?? CTFontCreateUIFontForLanguage(.userFixedPitch, pointSize, nil)
        // SAFETY: a nil matrix is CTFontCreateWithName's documented identity transform; the name is a CFString
        // that lives for the call.
        _ = unsafe CTFontCreateWithName("AppleColorEmoji" as CFString, pointSize, nil)
        if let face { _ = CTFontCopyDefaultCascadeListForLanguages(face, nil) }
    }

    /// The first installed face of `family`, matched as Ghostty's discovery matches it (a family descriptor
    /// against a font collection); nil when no face matches.
    private static func matchingFace(family: String) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: family] as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let matches = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor],
              let first = matches.first else { return nil }
        // SAFETY: a nil matrix is CTFontCreateWithFontDescriptor's documented identity transform; `first` is a
        // descriptor this function holds for the call.
        return unsafe CTFontCreateWithFontDescriptor(first, pointSize, nil)
    }
}
