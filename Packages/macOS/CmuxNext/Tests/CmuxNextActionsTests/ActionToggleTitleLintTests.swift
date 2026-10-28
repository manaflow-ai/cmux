import CmuxNextActions
import Foundation
import Testing

/// Lawrence 2026-10-27 (Cmd-Shift-P, "pin workspace" showed "Pin/Unpin Workspace"): "it doesn't
/// tell me if something is pinned ... I don't want to have a toggle thing. I want the toggle thing
/// to be explicit about what is going to happen." No catalog title may name both sides of a toggle
/// ("Pin/Unpin Tab", "Show/Hide Label") or say only "Toggle …": a toggle declares the two titles it
/// shows (``ActionToggleTitles``) and every surface shows the one that names the change it makes.
@Suite struct ActionToggleTitleLintTests {
    /// Titles where a slash is part of a name, not a choice between two actions.
    static let slashNames: Set<String> = []

    /// Toggles whose state the app cannot read synchronously, so no title for one state could be
    /// trusted: they say both sides in words ("Show or Hide Event Inspector"). The agent pane's
    /// panels and React Grab keep their state in the page, DevTools keeps no recording state, the
    /// palette's own Cmd-K key is not a registry action, and Turn a Setting On or Off… is a picker.
    /// Shrink only: a toggle whose state becomes readable moves to ``ActionToggleTitles``.
    static let statelessToggles: Set<ActionID> = [
        "agentPane.toggleSessionInfo", "agentPane.toggleInspector", "agentPane.toggleDisplaySettings",
        "agentPane.toggleMinimap", "toggleReactGrab", "devtools.togglePerformanceRecording",
        "paletteKey.toggleActions", "palette.toggleSetting",
    ]

    /// "Pin or Unpin Chat", "Palette: Show or Hide Actions": a toggle that names both sides in words.
    static func namesBothSidesInWords(_ title: String) -> Bool {
        title.range(of: #"(?:^|: )\w+ or \w+ "#, options: .regularExpression) != nil
    }

    /// A title is a toggle in disguise when it pairs two words with a slash or starts with "Toggle".
    static func isAmbiguousToggle(_ title: String) -> Bool {
        if title.hasPrefix("Toggle ") || title == "Toggle" { return true }
        return title.range(of: #"\p{L}/\p{L}"#, options: .regularExpression) != nil
    }

    @Test func noCatalogTitleNamesBothSidesOfAToggle() {
        let offenders = ActionCatalog.all
            .filter { Self.isAmbiguousToggle($0.title) && !Self.slashNames.contains($0.title)
                || Self.namesBothSidesInWords($0.title) && !Self.statelessToggles.contains($0.id) }
            .map { "\($0.id.rawValue): \($0.title)" }
        #expect(offenders.isEmpty, "Declare ActionToggleTitles instead of: \(offenders.joined(separator: ", "))")
    }

    @Test func theLintCatchesBothShapes() {
        #expect(Self.isAmbiguousToggle("Pin/Unpin Workspace"))
        #expect(Self.isAmbiguousToggle("Add Workspace to Top/Remove from Top"))
        #expect(Self.isAmbiguousToggle("Toggle Left Sidebar"))
        #expect(!Self.isAmbiguousToggle("Pin Workspace"))
        #expect(!Self.isAmbiguousToggle("Toggled Things"))
        #expect(!Self.isAmbiguousToggle("Split 1 / 2"))
        #expect(Self.namesBothSidesInWords("Pin or Unpin Chat"))
        #expect(Self.namesBothSidesInWords("Palette: Show or Hide Actions"))
        #expect(!Self.namesBothSidesInWords("Turn a Setting On or Off…"))
    }
}
