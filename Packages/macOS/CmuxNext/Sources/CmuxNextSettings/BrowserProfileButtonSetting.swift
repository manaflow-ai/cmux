/// `browser.profileButton` in cmux-next.json: how the toolbar's Profile button shows (cmuxterm-hq
/// RFD 0050 D1, as the design court shipped it: docs/design/proposals/2026-11-23-the-browser-profile-button-
/// with-one-profile-pinned-in-its-su.md). A default ships in its subtle form, bolder forms are levels a
/// person picks (Leo 2026-11-23, "the point is probably subtlety when it comes to defaults changes/additions"):
///
/// - `quiet` (default): only while it says something (two or more person profiles, an incognito tab, the
///   Agents profile), drawn in the toolbar's ink;
/// - `always`: in every browser pane, in the toolbar's ink;
/// - `color`: in every browser pane, as a disc in the profile's color.
///
/// The button still has to be pinned (`browser.toolbarButtons`, where it is by default). The app reads the
/// effective root (``current(_:)``), as for the toolbar's pins. `configPath`, `fallback` and the
/// `BrowserProfileButtonStyle` cases come from schemas/settings/source/browser.json.
public nonisolated enum BrowserProfileButtonSetting {
    /// The style in `root`; absent or bad is the default (a bad value also gets a diagnostic, in `parse`).
    public static func read(_ root: JSONValue) -> BrowserProfileButtonStyle {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserProfileButtonStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let style = value.stringValue.flatMap(BrowserProfileButtonStyle.init(rawValue:)) else {
            let known = BrowserProfileButtonStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected one of \(known)"))
            return fallback
        }
        return style
    }

    /// The style the app applies: the effective root, so a managed value decides.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserProfileButtonStyle {
        read(settings.snapshot.root)
    }
}
