public import Foundation

/// Whether this process's native text darkens glyph stems, fixed for the life of the process.
///
/// AppKit (`NSTextField`, `NSTextView`, SwiftUI `Text`, `draw(_:)` contexts) reads the
/// `AppleFontSmoothing` default once, when it first draws text, and keeps it until the app quits;
/// a later write does not change it. ``apply(_:to:)`` writes that default in the app's own domain
/// from ``FontSmoothing`` before the first window, so one value covers every AppKit and SwiftUI
/// text path. Text cmux draws into its own bitmaps (``GlyphMask``) sets smoothing on the context
/// explicitly, which the default does not reach, so it reads ``current`` and draws the same
/// weight. Ghostty's terminal glyphs keep their own `font-thicken` choice the same way.
///
/// ```swift
/// // SettingsController.readAtLaunch, from applicationDidFinishLaunching before any window:
/// ProcessFontSmoothing.apply(read.snapshot.fontSmoothing, to: .standard)
/// // A custom drawing:
/// ctx.setShouldSmoothFonts(ProcessFontSmoothing.current.smoothsStems)
/// ```
public nonisolated struct ProcessFontSmoothing: Sendable, Equatable {
    /// The default AppKit and Core Graphics read: 0 is off, a missing key or any other number on.
    public static let defaultsKey = "AppleFontSmoothing"

    /// True when glyph stems draw darkened (the heavier macOS look).
    public let smoothsStems: Bool

    /// - Parameter smoothsStems: true for the heavier macOS look, false for thin strokes.
    public init(smoothsStems: Bool) {
        self.smoothsStems = smoothsStems
    }

    /// The smoothing AppKit takes from `defaults`: off only when ``defaultsKey`` holds 0.
    ///
    /// - Parameter defaults: the app's defaults (its own domain over the global one).
    public init(defaults: UserDefaults) {
        let value = defaults.object(forKey: Self.defaultsKey) as? NSNumber
        self.smoothsStems = value.map { $0.intValue != 0 } ?? true
    }

    /// This process's smoothing, read once on first use, as AppKit reads it once.
    ///
    /// Read only after ``apply(_:to:)`` ran at launch (the first text draw comes after it).
    // A constant of the process, not shared mutable state: AppKit latches the same default the
    // same way, and UserDefaults is Apple-documented thread-safe.
    public static let current = ProcessFontSmoothing(defaults: .standard)

    /// The smoothing of the text cmux draws into its own bitmaps (``GlyphMask``: ``ChromeLabel``,
    /// ``ChromeTextLayer``, so the sidebar, tabs and most chrome), which follows
    /// `appearance.fontSmoothing` live, as web pages do.
    ///
    /// It reads the app's defaults now, where ``apply(_:to:)`` writes the setting at launch and on
    /// each change: at launch it is ``current``; after a change it is the new value, while AppKit's
    /// own text keeps ``current`` until a restart (https://github.com/manaflow-ai/cmux/issues/44844:
    /// the sidebar kept the launch's weight after a change while pages changed at once).
    public static var chrome: ProcessFontSmoothing { ProcessFontSmoothing(defaults: .standard) }

    /// ``apply(_:to:)`` to the app's defaults, for a settings change while the app runs: when
    /// ``chrome`` changes, every ``ChromeLabel`` and ``ChromeTextLayer`` in the app's windows draws
    /// again in it (``GlyphMask/weight(of:smoothing:)`` keys their images by it).
    ///
    /// - Returns: the smoothing chrome text now draws with.
    @MainActor @discardableResult
    public static func applyLive(_ mode: FontSmoothing) -> ProcessFontSmoothing {
        let before = chrome
        let after = apply(mode, to: .standard)
        if after != before { ChromeTextRefresh.all() }
        return after
    }

    /// Writes `mode` for AppKit to read at its first text draw, and returns what text then draws.
    ///
    /// ``FontSmoothing/antialiased`` writes 0 and ``FontSmoothing/subpixel`` writes 2 in the app's
    /// own domain (over any global value; macOS 27 draws 1, 2 and 3 alike); ``FontSmoothing/auto``
    /// removes the app's value, so the Mac's global choice applies. A value already in place is not
    /// written again. AppKit ignores a change after its first text draw, so the app calls this before
    /// its first window and again on each change, for the next launch.
    ///
    /// - Parameters:
    ///   - mode: the `appearance.fontSmoothing` setting.
    ///   - defaults: the app's defaults (`.standard` in the app; a suite in tests).
    /// - Returns: the smoothing `defaults` now gives.
    @discardableResult
    public static func apply(_ mode: FontSmoothing, to defaults: UserDefaults) -> ProcessFontSmoothing {
        let saved = (defaults.object(forKey: defaultsKey) as? NSNumber)?.intValue
        switch mode {
        case .auto:
            defaults.removeObject(forKey: defaultsKey)
        case .antialiased:
            if saved != 0 { defaults.set(0, forKey: defaultsKey) }
        case .subpixel:
            if saved == nil || saved == 0 { defaults.set(2, forKey: defaultsKey) }
        }
        return ProcessFontSmoothing(defaults: defaults)
    }
}
