public import CmuxNextDesign
import CoreGraphics

/// The menu and popover look keys in cmux-next.json or a theme file: `appearance.menu.*` (corner, edge,
/// shadow, fill, padding, hover corner, row height, shortcut column, section labels, separators,
/// destructive rows, submenu placement, second lines) and `appearance.popover.*` (padding, header,
/// progress track), read into a ``MenuLook``. A missing key is today's look; a bad value is
/// today's look plus a diagnostic (the daemon refuses it first, through the schema rows). Paths,
/// ranges and choice values are generated from schemas/settings/source/appearance.json (list
/// `menuLook`). A theme file sets them like any other `appearance.*` key, and a save applies them
/// live: the snapshot reapplies, ``DesignSettings/menuLook`` changes, the next menu opens in it and
/// every page repaints (``WebTheme/pushInputs``).
public nonisolated struct MenuLookSetting: Sendable {
    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> MenuLook {
        var look = MenuLook()
        func points(_ path: [String], _ range: ClosedRange<Double>) -> CGFloat? {
            guard let value = root.value(at: path) else { return nil }
            guard let number = value.doubleValue, number.isFinite else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                      message: "expected a number from \(range.lowerBound) to \(range.upperBound)"))
                return nil
            }
            if !range.contains(number) {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                      message: "clamped to \(range.lowerBound)...\(range.upperBound)"))
            }
            return CGFloat(min(max(number, range.lowerBound), range.upperBound))
        }
        func choice<Value: RawRepresentable & CaseIterable>(_ path: [String], _ fallback: Value) -> Value
        where Value.RawValue == String {
            guard let value = root.value(at: path) else { return fallback }
            guard let text = value.stringValue, let parsed = Value(rawValue: text) else {
                let choices = Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                                      message: "expected one of \(choices)"))
                return fallback
            }
            return parsed
        }
        look.cornerRadius = points(menuCornerRadiusPath, menuCornerRadiusRange)
        look.borderOpacity = points(menuBorderOpacityPath, menuBorderOpacityRange)
        look.shadow = choice(menuShadowPath, .standard)
        if let value = root.value(at: menuFillPath) {
            if let color = value.stringValue.flatMap(PaneChromeConfigParser.color(hex:)) {
                look.fill = color
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: menuFillPath.joined(separator: "."),
                                                      message: "expected \"#RRGGBB\" or \"#RRGGBBAA\""))
            }
        }
        look.padding = points(menuPaddingPath, menuPaddingRange)
        look.highlightRadius = points(menuHighlightRadiusPath, menuHighlightRadiusRange)
        look.rowHeight = points(menuRowHeightPath, menuRowHeightRange)
        look.shortcuts = choice(menuShortcutsPath, .standard)
        look.sectionLabel = choice(menuSectionLabelPath, .standard)
        look.separator = choice(menuSeparatorPath, .standard)
        look.destructiveInk = choice(menuDestructiveInkPath, .standard)
        look.submenu = choice(menuSubmenuPath, .standard)
        look.subtitle = choice(menuSubtitlePath, .standard)
        look.popoverPadding = points(popoverPaddingPath, popoverPaddingRange)
        look.popoverHeader = choice(popoverHeaderPath, .standard)
        look.progressHeight = points(popoverProgressHeightPath, popoverProgressHeightRange)
        look.progressFill = choice(popoverProgressFillPath, .standard)
        return look
    }

    /// The look `snapshot` asks for.
    public static func effective(in snapshot: CmuxConfigSnapshot) -> MenuLook {
        var ignored: [SettingsDiagnostic] = [] // the snapshot's parse reported them (`CmuxConfigSnapshot.parse`)
        return parse(snapshot.root, diagnostics: &ignored)
    }
}

extension SettingsApplier {
    /// Copies the menu and popover look keys into `design`, writing only a change.
    static func applyMenuLook(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        let look = MenuLookSetting.effective(in: snapshot)
        if design.menuLook != look { design.menuLook = look }
    }
}
