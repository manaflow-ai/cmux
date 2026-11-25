import AppKit

/// `appearance.appFont`: the font family cmux's interface draws in, any family installed on this Mac
/// (proportional ones too; the terminal rows list the fixed-pitch ones). Unset (the default) is the
/// system font, as before. Every web page takes it as its `--font-ui` live (`WebTheme.appFontStack`);
/// native chrome text takes it too while `experiments.appFontChrome` is on (`CheckedFont`). Leo,
/// 2026-11-08: "there's no whole app font change thing ... i wanna just be able to see different
/// fonts just like how i can see different themes as preview".
public nonisolated struct AppFontSetting: Sendable {
    // `configPath` is generated from schemas/settings/source/appearance.json.

    public init() {}

    /// The family in `root`, trimmed; nil when unset, blank or not a family name the app accepts
    /// (`TerminalFontSetting.isValidFamily`: no `#`, `=`, `"` or control characters).
    public func value(in root: JSONValue) -> String? {
        guard let text = root.value(at: Self.configPath)?.stringValue else { return nil }
        let family = text.trimmingCharacters(in: .whitespaces)
        return TerminalFontSetting().isValidFamily(family) ? family : nil
    }

    /// Every installed family, proportional ones too, sorted, listed once per launch: the App Font
    /// row's list (validation `domain:ui_font_family`, the page's `ui_font_families` domain).
    @MainActor public static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { TerminalFontSetting().isValidFamily($0) && !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// The families a font row offers: every installed one for the App Font, else `fixedPitch`.
    @MainActor public static func families(for key: String, fixedPitch: [String]) -> [String] {
        key == configPath.joined(separator: ".") ? installedFamilies : fixedPitch
    }
}
