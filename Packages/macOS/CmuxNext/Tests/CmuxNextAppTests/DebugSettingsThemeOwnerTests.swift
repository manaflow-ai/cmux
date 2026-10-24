import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Testing

/// The theme Debug Settings draws in belongs to its model (``DebugSettingsModel/theme``), not to
/// the process: a model follows the scope it is told to (the window, pane and page swatches of that
/// model), and another model (a test's, or the next one after every view closed) keeps its own.
@MainActor
struct DebugSettingsThemeOwnerTests {
    private static let section = TunableSection(id: "themeOwnerTest", title: "Theme Owner", symbol: "paintpalette", order: 999)
    private static let color = TunableDescriptor(key: "themeOwnerTest.color", section: section, label: "Color", help: "",
                                                 kind: .color, defaultSource: .fixed(.color(.textPrimary)))

    /// The swatch the page draws for the `textPrimary` option of the one color tunable.
    private static func swatch(_ model: DebugSettingsModel) -> String? {
        let state = model.pageState()
        guard case .array(let groups)? = state["groups"], case .array(let rows)? = groups.first?["rows"],
              case .array(let options)? = rows.first?["control"]?["options"] else { return nil }
        let option = options.first { $0["value"]?.stringValue == TunableColor.textPrimary.rawValue }
        return option?["swatch"]?.stringValue
    }

    /// A room scope whose text color is not the app theme's.
    private static func roomScope() throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let palette = [0x1A1A1A, 0xE0533D, 0x3FB950, 0xD29922, 0x3B82F6, 0xA371F7, 0x2DD4BF, 0xC9D1D9]
        let input = ThemeInput(background: ThemeRGB(hex: 0x0E1116), foreground: ThemeRGB(hex: 0x12AB34),
                               palette: palette.map { ThemeRGB(hex: UInt32($0)) })
        scope.setOverride(try #require(ThemeSpec("Theme Owner Room")), input: input, animated: false)
        return scope
    }

    @Test func aModelDrawsInTheScopeItFollows() throws {
        let scope = try Self.roomScope()
        let model = DebugSettingsModel(store: TunableStore(), descriptors: [Self.color])
        model.followTheme(scope)
        #expect(model.theme.scope === scope)
        #expect(Self.swatch(model) != nil, "the page drew no textPrimary swatch")
        #expect(Self.swatch(model) == TunableColor.textPrimary.resolve(in: scope.tokens).withAlpha(1).description)
    }

    @Test func anotherModelDoesNotFollowTheFirstModelsScope() throws {
        let scope = try Self.roomScope()
        try #require(scope.tokens.textPrimary != ThemeScope.app.tokens.textPrimary, "the room's text color is the app's")
        let followed = DebugSettingsModel(store: TunableStore(), descriptors: [Self.color])
        let other = DebugSettingsModel(store: TunableStore(), descriptors: [Self.color])
        followed.followTheme(scope)
        #expect(other.theme.scope === ThemeScope.app, "a second model follows the first model's scope")
        #expect(Self.swatch(other) == TunableColor.textPrimary.resolve(in: ThemeScope.app.tokens).withAlpha(1).description,
                "a second model drew its swatches in the first model's scope")
    }
}
