@testable import CmuxNextDesign
import Foundation
import Testing

/// `appearance.previousGlass` on: the web theme sends `glassLevels: "previous"`, so every page sets
/// `data-glass-levels="previous"` and webviews ui/glass/glass.css draws the glass numbers from before
/// the one glass system; off sends `current` (the bootstrap removes the attribute). Either way the
/// lens choice still rides `glass`, and the change repaints every open page (``WebTheme/pushInputs``).
@MainActor @Suite(.serialized) struct PreviousGlassWebThemeTests {
    private func payload(_ theme: WebTheme) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
    }

    @Test func onSendsPreviousAndOffSendsCurrent() throws {
        let design = DesignSettings.shared
        let before = design.previousGlass
        defer { design.previousGlass = before }
        design.previousGlass = false
        #expect(try payload(WebTheme(.unresolved))["glassLevels"] as? String == "current")
        design.previousGlass = true
        for mode in GlassLensMode.allCases {
            let sent = try payload(WebTheme(.unresolved, glass: mode))
            #expect(sent["glassLevels"] as? String == WebTheme.glassLevelsPrevious)
            #expect(sent["glass"] as? String == mode.rawValue)
        }
    }

    @Test func theBootstrapSetsAndClearsTheAttribute() {
        #expect(WebTheme.bootstrapScript.contains("root.setAttribute('data-glass-levels', 'previous')"))
        #expect(WebTheme.bootstrapScript.contains("root.removeAttribute('data-glass-levels')"))
    }

    @Test func turningItOnRepaintsOpenPages() {
        let design = DesignSettings.shared
        let before = design.previousGlass
        defer { design.previousGlass = before }
        design.previousGlass = false
        let offInputs = WebTheme.pushInputs
        design.previousGlass = true
        #expect(WebTheme.pushInputs != offInputs, "turning it on must repaint every open page")
    }
}
