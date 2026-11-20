import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". Every bundled theme (Ghostty's and cmux's own, each in the mode its colors give it)
/// as the App Theme: each element's ink on each ground it is drawn on (``ThemeElementAudit``)
/// holds its WCAG 2 minimum, and takes its color from the theme, not from the system's light or
/// dark appearance. Before the fix the sidebar's status dots were the system's blue, orange and
/// red: orange read 1.7:1 on every light theme, blue 1.4:1 on Blue Dolphin, and the unread blue
/// vanished on blue themes.
@MainActor @Suite(.serialized)
struct EveryThemeElementContrastTests {
    /// Grass's pressed row keeps 4.41:1, the most any ink reaches there (``CardNeverOpaqueTests``).
    static func allowed(_ sample: ThemeElementSample, theme: String) -> Bool {
        guard let floor = CardNeverOpaqueTests.pressedRowExemptions[theme], sample.ground == .pressedRow else { return false }
        // The 0.01 tolerance CardNeverOpaqueTests uses: the audit composites through NSColor (4.40:1).
        return !sample.followsSystemAppearance && sample.contrast >= floor - 0.01
    }

    @Test func everyElementReadsAndIsThemedInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        var failures: [String] = []
        var perKind: [String: Int] = [:]
        for theme in themes {
            let scope = ThemeScope(level: .workspace)
            scope.setOverride(try #require(ThemeSpec("Audit \(theme.name)")), input: theme.input, animated: false)
            for sample in ThemeElementAudit(scope: scope).failures where !Self.allowed(sample, theme: theme.name) {
                let why = sample.followsSystemAppearance ? "follows the system appearance"
                    : String(format: "%.2f:1 < %.1f:1", sample.contrast, sample.minimum)
                failures.append("\(theme.label): \(sample.element.rawValue) on \(sample.ground.rawValue): \(why)")
                perKind["\(sample.element.rawValue) on \(sample.ground.rawValue)", default: 0] += 1
            }
        }
        let kinds = perKind.sorted { $0.value > $1.value }.map { "\($0.value)x \($0.key)" }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures in \(kinds.count) kinds:\n"
            + kinds.joined(separator: "\n") + "\nfirst:\n" + failures.prefix(80).joined(separator: "\n")))
    }
}
