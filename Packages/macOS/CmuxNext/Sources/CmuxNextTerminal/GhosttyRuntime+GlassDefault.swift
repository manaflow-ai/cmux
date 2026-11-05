import CmuxNextDesign
import GhosttyNextKit

/// A new install's window is Glass (Leo, 2026-11-05: "new install should default to glass"): when the
/// Ghostty config files write neither `background-opacity` nor `background-blur`, a load takes them as
/// ``WindowBackgroundOverride/defaultTranslucentOpacity`` and `macos-glass-regular` instead of Ghostty's
/// opaque, unblurred defaults. A value someone wrote is a choice, not a default, so a written key keeps
/// its window: `background-opacity = 1` stays opaque. cmux.json's window background then lies over
/// either, as before (`backgroundOverrideLines`).
///
/// libghostty does not say whether a key was written, so cmux loads a marker value for each key
/// before the user's files: a file that writes the key replaces it, and a marker still there after the
/// files load means nobody wrote it.
///
/// ```swift
/// loadUnwrittenBackgroundMarkers(into: config)   // before the user's files
/// // ... the user's files load ...
/// for line in unwrittenBackgroundLines(opacity: &opacity, blur: &blur) { /* load it */ }
/// ```
extension GhosttyRuntime {
    /// The marker `background-opacity`: a value no one writes by hand.
    static let unwrittenOpacityMarker = 0.987_654_321
    /// The marker `background-blur` radius: a value no one writes by hand.
    static let unwrittenBlurMarker: Int16 = 251

    /// Loads the two markers, before the user's config files.
    static func loadUnwrittenBackgroundMarkers(into config: ghostty_config_t) {
        for line in ["background-opacity = \(unwrittenOpacityMarker)", "background-blur = \(unwrittenBlurMarker)"] {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
        }
    }

    /// The lines that replace whichever markers survived the user's files, and the values they set:
    /// neither key written is the default Glass window; one key written keeps it and puts Ghostty's
    /// own default back for the other.
    ///
    /// - Parameter opacity: The loaded `background-opacity`; set to what the lines make it.
    /// - Parameter blur: The loaded `background-blur`, Ghostty's C encoding; set likewise.
    /// - Returns: Lines for `ghostty_config_load_string`; empty when both keys were written.
    static func unwrittenBackgroundLines(opacity: inout Double, blur: inout Int16) -> [String] {
        let opacityWritten = abs(opacity - unwrittenOpacityMarker) > 1e-9
        let blurWritten = blur != unwrittenBlurMarker
        var lines: [String] = []
        if !opacityWritten {
            opacity = blurWritten ? 1 : WindowBackgroundOverride.defaultTranslucentOpacity
            lines.append("background-opacity = \(opacity)")
        }
        if !blurWritten {
            blur = opacityWritten ? 0 : -1
            lines.append(blur == -1 ? "background-blur = macos-glass-regular" : "background-blur = false")
        }
        return lines
    }
}
