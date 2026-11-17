public import CmuxNextDesign
import CmuxTheme
import CoreGraphics

/// Reads the Theme Flourishes settings (`appearance.accentGlow.*`, `appearance.tabClose.*`,
/// `appearance.sidebarHeader.*`, `appearance.paneArt.*`) into ``ThemeFlourishes``. The paths,
/// defaults and ranges are generated from schemas/settings/source/appearance.json; a bad value
/// keeps its default with a diagnostic. Community theme installs write these keys into each theme
/// file (cmux-customize `community::art`).
public nonisolated struct ThemeFlourishSetting: Sendable {
    public init() {}

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ThemeFlourishes {
        var reader = Reader(root: root)
        var flourishes = ThemeFlourishes()
        if let dark = reader.color(accentGlowDarkPath) {
            let light = reader.color(accentGlowLightPath) ?? dark
            let radius = reader.number(accentGlowRadiusPath, range: accentGlowRadiusRange) ?? accentGlowRadiusDefault
            let opacity = reader.number(accentGlowOpacityPath, range: accentGlowOpacityRange) ?? accentGlowOpacityDefault
            flourishes.accentGlow = .init(dark: dark, light: light, radius: CGFloat(radius), opacity: CGFloat(opacity))
        }
        let toDark = reader.color(tabCloseToDarkPath)
        let space = reader.choice(tabCloseInterpolationPath, tabCloseInterpolationValues) ?? tabCloseInterpolationDefault
        flourishes.tabClose = .init(from: reader.color(tabCloseFromPath), toDark: toDark,
                                    toLight: reader.color(tabCloseToLightPath) ?? toDark,
                                    space: ThemeColorSpace(rawValue: space) ?? .oklab)
        flourishes.sidebarHeader = Self.pair(light: reader.picture(sidebarHeaderLightPath), dark: reader.picture(sidebarHeaderDarkPath))
        let darkArt = reader.pictures(paneArtDarkPath)
        let lightArt = reader.pictures(paneArtLightPath)
        let count = max(darkArt.count, lightArt.count)
        flourishes.paneArt = (0..<count).compactMap { index in
            let dark = darkArt.isEmpty ? nil : darkArt[index % darkArt.count]
            let light = lightArt.isEmpty ? nil : lightArt[index % lightArt.count]
            return Self.pair(light: light, dark: dark)
        }
        diagnostics += reader.diagnostics
        return flourishes
    }

    /// One picture when both sides are the same or one is unset; a light/dark pair otherwise.
    static func pair(light: BackdropSelection?, dark: BackdropSelection?) -> BackdropSelection? {
        guard let shownDark = dark ?? light else { return nil }
        let shownLight = light ?? shownDark
        return shownLight == shownDark ? shownDark : .pair(light: shownLight, dark: shownDark)
    }

    /// Whether `value` is valid for `appearance.paneArt.*`: a list of fixed pictures.
    static func acceptsPictures(_ value: JSONValue) -> Bool {
        value.arrayValue?.allSatisfy(BackdropSelectionSetting.acceptsPicture) ?? false
    }

    /// The keys whose values are pictures a theme file may write relative to its folder.
    static let picturePaths = [sidebarHeaderDarkPath, sidebarHeaderLightPath]
    static let pictureListPaths = [paneArtDarkPath, paneArtLightPath]

    private struct Reader {
        let root: JSONValue
        var diagnostics: [SettingsDiagnostic] = []

        private mutating func fail(_ path: [String], _ message: String) {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: message))
        }

        mutating func color(_ path: [String]) -> ThemeRGB? {
            guard let value = root.value(at: path), value != .null else { return nil }
            guard let color = value.stringValue.flatMap({ ThemeRGB(cssHex: $0) }) else { fail(path, "expected a #RRGGBB color"); return nil }
            return color
        }

        mutating func number(_ path: [String], range: ClosedRange<Double>) -> Double? {
            guard let value = root.value(at: path) else { return nil }
            guard let number = value.doubleValue, number.isFinite else { fail(path, "expected a number"); return nil }
            return min(max(number, range.lowerBound), range.upperBound)
        }

        mutating func choice(_ path: [String], _ values: [String]) -> String? {
            guard let value = root.value(at: path) else { return nil }
            guard let text = value.stringValue, values.contains(text) else {
                fail(path, "expected one of \(values.map { "\"\($0)\"" }.joined(separator: ", "))")
                return nil
            }
            return text
        }

        mutating func picture(_ path: [String]) -> BackdropSelection? {
            guard let value = root.value(at: path), value != .null else { return nil }
            guard let picture = value.stringValue.flatMap(BackdropSelectionSetting.picture) else {
                fail(path, "expected a fixed picture (file: and an absolute path, system:, desktop or a listed painting)")
                return nil
            }
            return picture
        }

        mutating func pictures(_ path: [String]) -> [BackdropSelection] {
            guard let value = root.value(at: path), value != .null else { return [] }
            guard let items = value.arrayValue else { fail(path, "expected a list of pictures"); return [] }
            let pictures = items.compactMap { $0.stringValue.flatMap(BackdropSelectionSetting.picture) }
            if pictures.count != items.count { fail(path, "expected a list of fixed pictures (file: and an absolute path)") }
            return pictures
        }
    }
}
