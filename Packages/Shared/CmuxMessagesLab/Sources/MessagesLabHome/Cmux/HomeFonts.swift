import AppKit

/// Fonts the off-main row renderers share for the life of the process.
///
/// AppKit's `monospacedSystemFont(ofSize:weight:)` is annotated nonnull but
/// returns nil when another thread releases the last instance of that font
/// while the lookup runs (measured on macOS 27.0.1: about 1 in 1000 calls
/// from 8 threads that each make and drop the font; 0 while one instance
/// stays alive). RowBitmaps renders three rows at once and a resize
/// re-renders every visible row, so a code font made and dropped per run
/// came back nil and `addAttribute` threw "nil value" (cx-qpqs). One font
/// held here keeps the instance alive, so no lookup races its release.
enum HomeFonts {
    /// Inline code and code blocks in an agent's Markdown (TextLayout.attributed):
    /// SF Mono one point under the body. Built from the body font's monospaced
    /// design (the same font as `monospacedSystemFont(ofSize: 12, weight: .regular)`)
    /// through APIs that really return optionals, so a failure falls back to the
    /// user's fixed-pitch font instead of a nil inside the attributes.
    static let code: NSFont = {
        let size = Fixture.bodyFont.pointSize - 1
        if let d = Fixture.bodyFont.fontDescriptor.withDesign(.monospaced), let f = NSFont(descriptor: d, size: size) { return f }
        return NSFont.userFixedPitchFont(ofSize: size) ?? Fixture.bodyFont
    }()
}
