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

    /// A title is a toggle in disguise when it pairs two words with a slash or starts with "Toggle".
    static func isAmbiguousToggle(_ title: String) -> Bool {
        if title.hasPrefix("Toggle ") || title == "Toggle" { return true }
        return title.range(of: #"\p{L}/\p{L}"#, options: .regularExpression) != nil
    }

    @Test func noCatalogTitleNamesBothSidesOfAToggle() {
        let offenders = ActionCatalog.all
            .filter { Self.isAmbiguousToggle($0.title) && !Self.slashNames.contains($0.title) }
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
    }
}
