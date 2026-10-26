import CmuxNextCompat
import CoreText
public import Foundation
import Metal

/// The first terminal surface's one-time system costs, paid on a launch
/// thread while AppKit starts instead of on the main thread inside
/// `ghostty_app_new` and the first `ghostty_surface_new`.
///
/// - Metal: the process's first device enumeration loads the driver
///   (`ghostty_app_new` enumerates on the main thread to pick its device,
///   ghostty-next `src/renderer/metal/Device.zig`), and a device's first
///   command queue pays its setup. This picks the device the same way and
///   makes and drops one queue on it.
/// - CoreText: the first font query loads the system font registry. This
///   loads Apple Color Emoji (libghostty adds it to every grid), matches each
///   configured `font-family` as libghostty's `CoreText.discover` does, and
///   reads the fallback cascade of the primary face.
///
/// Thread-safe: it shares no state, and the Metal and CoreText objects it
/// makes are thread-safe and dropped; only the frameworks' process-wide
/// state stays warm. libghostty warms both off the main thread itself
/// (`src/App.zig`, `App.create`), but only after the main thread picked its
/// device there. Its shader pipelines stay there: the metallib is inside
/// libghostty, so warming them earlier is a fork change.
public nonisolated struct TerminalLaunchPrefetch: Sendable {
    /// The `font-family` values to match, at most ``maximumFamilies``.
    public let fontFamilies: [String]

    /// Families past this many are fallbacks the first frame rarely needs.
    static let maximumFamilies = 4

    /// `CMUX_NEXT_TERMINAL_PREFETCH=0` turns the prefetch off, for a
    /// before/after measurement on one build.
    static let disableKey = "CMUX_NEXT_TERMINAL_PREFETCH"

    public init(fontFamilies: [String]) {
        var seen = Set<String>()
        self.fontFamilies = Array(fontFamilies.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.maximumFamilies))
    }

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[disableKey] != "0"
    }

    /// The prefetch for the user's Ghostty config: the families its default
    /// files name (or `CMUX_NEXT_GHOSTTY_CONFIG`'s file alone, as the runtime
    /// loads it). Includes and cmux.json's `terminal.fontFamily` are not
    /// read; their faces match on the first surface as before.
    public static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(fontFamilies: families(inFiles: configFiles(environment: environment)))
    }

    static func configFiles(environment: [String: String]) -> [String] {
        if let path = environment[GhosttyRuntime.configOverrideKey], !path.isEmpty { return [path] }
        return GhosttyRuntime.defaultConfigCandidatePaths(environment: environment)
    }

    /// Every family `paths` leave configured, in order (a `font-family = ""`
    /// clears the ones before it, as in Ghostty).
    static func families(inFiles paths: [String]) -> [String] {
        var families: [String] = []
        for path in paths {
            guard let text = try? String(blockingContentsOfFile: path, encoding: .utf8) else { continue }
            families = GhosttyConfigFontFamily.fontFamilies(configText: text, after: families)
        }
        return families
    }

    /// Runs ``configured(environment:)`` on its own user-initiated thread,
    /// unless `CMUX_NEXT_TERMINAL_PREFETCH=0`; `mark` runs on that thread.
    /// Not behind the launch warm-up's action catalog (50-70 ms): it has to
    /// end before the main thread starts the Ghostty runtime.
    public static func startAtLaunch(mark: @escaping @Sendable (String) -> Void) {
        guard isEnabled() else { return }
        let thread = Thread { Self.configured().run(mark: mark) }
        thread.name = "cmux-next terminal prefetch"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs the prefetch on the calling thread; `mark` gets
    /// `terminal_prefetch.metal` and `terminal_prefetch.fonts` as each part
    /// ends (launch marks, beside `first_terminal_surface_created`).
    public func run(mark: (String) -> Void = { _ in }) {
        Self.prefetchMetal()
        mark("terminal_prefetch.metal")
        prefetchFonts()
        mark("terminal_prefetch.fonts")
    }

    private static func prefetchMetal() {
        var chosen: (any MTLDevice)?
        for device in MTLCopyAllDevices() where !device.isHeadless {
            chosen = device
            if device.isRemovable || device.isLowPower { break }
        }
        guard let chosen else { return }
        // The properties libghostty's Device.init reads next.
        _ = chosen.hasUnifiedMemory
        _ = chosen.supportsFamily(.apple3)
        _ = chosen.makeCommandQueue()
    }

    private func prefetchFonts() {
        let size: CGFloat = 12
        _ = CTFontCreateWithName("Apple Color Emoji" as CFString, size, nil)
        for family in fontFamilies {
            let attributes = [kCTFontFamilyNameAttribute as String: family] as CFDictionary
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
            let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
            _ = CTFontCollectionCreateMatchingFontDescriptors(collection)
        }
        let primary = fontFamilies.first.map { CTFontCreateWithName($0 as CFString, size, nil) }
            ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
        if let primary { _ = CTFontCopyDefaultCascadeListForLanguages(primary, CFLocaleCopyPreferredLanguages()) }
    }
}
