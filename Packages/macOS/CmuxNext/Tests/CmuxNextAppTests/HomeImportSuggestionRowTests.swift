import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextImportCards
import CmuxNextImportSuggestions
import Testing

/// Leo 2026-10-21 on nightly 331e2e9 ("WHAT IS THIS"): Home's import cards ("Bring your stuff to
/// cmux", a Claude Code card and a Codex card) floated over the Chief's transcript at a fixed
/// 80 pt from the column's top, so the chat showed through and around them. The suggestion is
/// now one compact glass row on the Chief's front page (the empty Chief conversation's first-run
/// panel), in the panel's own layout, never over a conversation.
@MainActor @Suite(.serialized) struct HomeImportSuggestionRowTests {
    static func card(_ id: String, kind: ImportSourceKind, title: String, facts: String) -> ImportCard {
        ImportCard(id: id, kind: kind, app: nil, title: title, facts: facts, benefit: "Your chats show in cmux.",
                   state: .ready, primary: .init(.start, "Show Chats"),
                   secondary: [.init(.more, "More Options…"), .init(.dismiss, "Not Now")])
    }

    static let two = ImportCardList(title: "Bring your stuff to cmux", cards: [
        card("claudeCode", kind: .claudeCode, title: "Claude Code", facts: "1,002 sessions"),
        card("codex", kind: .codex, title: "Codex", facts: "1,118 threads"),
    ])

    static func row(pressed: @escaping (String, ImportCardAction) -> Void = { _, _ in },
                    showAll: @escaping () -> Void = {}) -> ImportSuggestionRowView {
        let row = ImportSuggestionRowView(press: pressed, showAll: showAll)
        row.frame = NSRect(x: 0, y: 0, width: HomeFirstRunView.maxWidth, height: ImportSuggestionRowView.height)
        return row
    }

    /// Two suggestions are one row: the first one's name and facts, its button and Not Now, and
    /// Show All for the rest. No heading, no second card, no benefit paragraph.
    @Test func twoSuggestionsAreOneCompactRow() {
        let row = Self.row()
        row.show(Self.two)
        row.layoutSubtreeIfNeeded()
        #expect(!row.isHidden)
        #expect(row.fittingSize.height <= ImportSuggestionRowView.height)
        #expect(row.titleLabel.stringValue == "Claude Code")
        #expect(row.factsLabel.stringValue == "1,002 sessions")
        #expect(row.actions.map(\.title) == ["Show Chats", "Not Now"])
        #expect(!row.showAll.isHidden)
        let texts = row.descendantTexts
        #expect(!texts.contains { $0.contains("Codex") || $0.contains("Bring your stuff") || $0.contains("Your chats") })
    }

    /// One suggestion has nothing more to show: no Show All.
    @Test func oneSuggestionHasNoShowAll() {
        let row = Self.row()
        row.show(ImportCardList(title: Self.two.title, cards: [Self.two.cards[0]]))
        #expect(row.showAll.isHidden)
    }

    /// Not Now on the row dismisses the suggestion it shows; its button starts it; Show All opens
    /// Settings › Import.
    @Test func theRowsButtonsRunTheShownSuggestionsActions() {
        var pressed: [String] = []
        var settings = 0
        let row = Self.row(pressed: { pressed.append("\($0):\($1.rawValue)") }, showAll: { settings += 1 })
        row.show(Self.two)
        for button in row.actions { button.performClick(nil) }
        row.showAll.performClick(nil)
        #expect(pressed == ["claudeCode:start", "claudeCode:dismiss"])
        #expect(settings == 1)
    }

    /// Nothing to suggest: the row is gone and says it changed, so its panel lays out without it.
    @Test func nothingToSuggestHidesTheRow() {
        let row = Self.row()
        var changes = 0
        row.onChange = { changes += 1 }
        row.show(Self.two)
        row.show(.empty)
        #expect(row.isHidden)
        #expect(changes == 2)
    }

    /// The row is the sidebar cards' glass veil, never an opaque card.
    @Test func theRowIsGlass() {
        let row = Self.row()
        #expect(row.surface is CardSurfaceView)
    }

    /// The Chief's front page holds the row in its own column, under the action rows and inside
    /// the panel: nothing floats over the conversation's top.
    @Test func theFrontPageHoldsTheRowUnderItsActions() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let row = Self.row()
        row.show(Self.two)
        panel.accessory = row
        panel.layoutSubtreeIfNeeded()
        #expect(row.superview != nil)
        #expect(row.isDescendant(of: panel))
        let place = panel.convert(row.bounds, from: row)
        let pet = panel.convert(panel.pet.bounds, from: panel.pet)
        #expect(place.minY >= pet.maxY)
        #expect(panel.bounds.contains(place))
        #expect(abs(place.width - pet.width) < 1)
        #expect(abs(place.minX - pet.minX) < 1)
    }

    /// A hidden row leaves no gap: the panel is laid out as with no row at all.
    @Test func aHiddenRowTakesNoSpace() {
        let plain = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        plain.layoutSubtreeIfNeeded()
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let row = Self.row()
        row.show(.empty)
        panel.accessory = row
        panel.layoutSubtreeIfNeeded()
        let top = { (view: HomeFirstRunView) in view.convert(view.agent.bounds, from: view.agent).minY }
        #expect(abs(top(plain) - top(panel)) < 1)
    }

    /// The row goes when the host takes it away.
    @Test func clearingTheAccessoryRemovesTheRow() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let row = Self.row()
        row.show(Self.two)
        panel.accessory = row
        panel.accessory = nil
        #expect(row.superview == nil)
    }
}

extension NSView {
    /// Every label's and button's text under this view.
    fileprivate var descendantTexts: [String] {
        var texts: [String] = []
        if let field = self as? NSTextField { texts.append(field.stringValue) }
        if let button = self as? NSButton, !button.isHidden { texts.append(button.title) }
        for child in subviews where !child.isHidden { texts += child.descendantTexts }
        return texts
    }
}
