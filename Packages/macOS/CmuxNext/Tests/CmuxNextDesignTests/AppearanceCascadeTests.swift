@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The appearance cascade (plans/cmux-next/appearance-scopes-DESIGN.md): app < window <
/// workspace < rule < pane < tab, each level overriding the ones before, with the source of
/// every value, and reset to inherited by removing a level's value.
struct AppearanceCascadeTests {
    @Test func theMostSpecificLevelWinsAndNamesItsSource() throws {
        let cascade = AppearanceCascade(layers: [
            .app: [.theme: "Nord", .fontSize: "13"],
            .workspace: [.theme: "Rose Pine", .tint: "blue"],
            .pane: [.tint: "red"],
        ])
        #expect(cascade.resolved(.theme) == AppearanceCascade.Resolved(value: "Rose Pine", source: .workspace))
        #expect(cascade.resolved(.tint) == AppearanceCascade.Resolved(value: "red", source: .pane))
        #expect(cascade.resolved(.fontSize) == AppearanceCascade.Resolved(value: "13", source: .app))
        #expect(cascade.resolved(.cursorStyle) == nil)
    }

    @Test func aRuleBeatsTheWorkspaceButNotThePersonsPanePick() {
        var cascade = AppearanceCascade(layers: [.workspace: [.tint: "blue"], .rule: [.tint: "red"]])
        #expect(cascade.resolved(.tint)?.source == .rule)
        cascade.set(.tint, "green", at: .pane)
        #expect(cascade.resolved(.tint)?.value == "green")
    }

    @Test func resetShowsTheInheritedValueAgain() {
        var cascade = AppearanceCascade(layers: [.window: [.theme: "Nord"], .pane: [.theme: "Vesper"]])
        cascade.reset(.theme, at: .pane)
        #expect(cascade.resolved(.theme) == AppearanceCascade.Resolved(value: "Nord", source: .window))
        #expect(cascade.inherited(.theme, below: .window) == nil)
    }

    @Test func inheritedIsWhatResetWouldShow() {
        let cascade = AppearanceCascade(layers: [.app: [.fontSize: "13"], .workspace: [.fontSize: "16"], .tab: [.fontSize: "20"]])
        #expect(cascade.inherited(.fontSize, below: .tab) == AppearanceCascade.Resolved(value: "16", source: .workspace))
    }

    @Test(arguments: [
        (AppearanceProperty.blur, AppearanceLevel.pane, false),
        (.blur, .window, true),
        (.background, .tab, false),
        (.background, .pane, true),
        (.fontSize, .tab, true),
        (.tint, .app, false),
    ])
    func eachPropertyIsSettableOnlyWhereItMeansSomething(_ property: AppearanceProperty, _ level: AppearanceLevel, _ allowed: Bool) {
        #expect(property.levels.contains(level) == allowed)
    }

    @Test(arguments: [
        (AppearanceProperty.fontSize, "14", true), (.fontSize, "5", false), (.fontSize, "big", false),
        (.cursorStyle, "bar", true), (.cursorStyle, "beam", false),
        (.tint, "purple", true), (.tint, "#12AB34", true), (.tint, "mauve", false),
        (.opacity, "0.5", true), (.opacity, "1.5", false),
        (.background, "inherit", false), (.background, "daily", true), (.background, "none", true),
        (.theme, "Rose Pine", true), (.theme, "", false), (.theme, "a\nb", false),
    ])
    func valuesAreValidated(_ property: AppearanceProperty, _ value: String, _ valid: Bool) {
        #expect(property.accepts(value) == valid)
    }
}
