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

    /// Reduce Transparency off, whatever this Mac's setting is.
    static let glass = ReduceTransparency(system: { false }, changes: NotificationCenter())

    static func row(width: CGFloat = HomeFirstRunView.maxWidth,
                    pressed: @escaping (String, ImportCardAction) -> Void = { _, _ in },
                    showAll: @escaping () -> Void = {}) -> ImportSuggestionRowView {
        let row = ImportSuggestionRowView(press: pressed, showAll: showAll, reduceTransparency: glass)
        row.frame = NSRect(x: 0, y: 0, width: width, height: ImportSuggestionRowView.height)
        return row
    }

    /// The row's controls a person can see: the buttons not hidden, with their frames in the row.
    static func visibleButtons(_ row: ImportSuggestionRowView) -> [(NSButton, NSRect)] {
        (row.actions + [row.showAll]).filter { !$0.isHiddenOrHasHiddenAncestor && $0.superview != nil }
            .map { ($0, row.convert($0.bounds, from: $0)) }
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

    /// The row is the sidebar cards' glass veil, never an opaque card: with Reduce Transparency
    /// off it paints a see-through veil with the glass rim and no opaque fill or hairline.
    @Test func theRowIsGlass() throws {
        let row = Self.row()
        row.surface.updateLayer()
        let fill = try #require(row.surface.layer?.backgroundColor)
        #expect(fill.alpha > 0)
        #expect(fill.alpha < 0.6)
        #expect(row.surface.rimView != nil)
        #expect(row.surface.layer?.borderWidth == 0)
    }

    /// At the front page's full width the name and what was found show whole, on two lines, with
    /// the button, Not Now and Show All beside them.
    @Test func atFullWidthNothingTruncates() {
        let row = Self.row()
        row.show(Self.two)
        row.layoutSubtreeIfNeeded()
        for label in [row.titleLabel, row.factsLabel] {
            #expect(label.frame.width >= ceil(label.intrinsicContentSize.width) - 0.5, "\(label.stringValue) truncates")
        }
        let title = row.convert(row.titleLabel.bounds, from: row.titleLabel)
        let facts = row.convert(row.factsLabel.bounds, from: row.factsLabel)
        #expect(!title.intersects(facts))
        #expect(abs(title.minX - facts.minX) < 1)
        #expect(!row.showAll.isHidden)
        #expect(row.actions.map(\.title) == ["Show Chats", "Not Now"])
    }

    /// Down to the narrowest Home pane (and past it) every control the row shows stays inside its
    /// glass: Show All goes first, then Not Now becomes an ✕ (still Not Now to VoiceOver), then the
    /// app icon. At every interface scale.
    @Test(arguments: [1.0, 1.25, 1.5] as [CGFloat])
    func narrowRowsKeepTheirControlsInsideTheGlass(scale: CGFloat) {
        for width in stride(from: CGFloat(360), through: 150, by: -10) {
            let row = Self.row(width: width)
            row.applyScale(scale)
            row.show(Self.two)
            row.setFrameSize(NSSize(width: width, height: row.intrinsicContentSize.height))
            row.layoutSubtreeIfNeeded()
            let shown = Self.visibleButtons(row)
            #expect(shown.contains { $0.0 === row.actions[0] }, "width \(width): the card's button shows")
            for (button, frame) in shown {
                #expect(frame.minX >= 0 && frame.maxX <= row.bounds.width + 0.5,
                        "width \(width) scale \(scale): \(button.accessibilityLabel() ?? button.title) at \(frame) spills past \(row.bounds.width)")
            }
        }
        let narrow = Self.row(width: 200)
        narrow.show(Self.two)
        narrow.layoutSubtreeIfNeeded()
        #expect(narrow.showAll.isHidden)
        let dismiss = narrow.actions[1]
        #expect(dismiss.imagePosition == .imageOnly)
        #expect(dismiss.accessibilityLabel() == "Not Now")
        // Not Now still dismisses in its compact form.
        var pressed: [ImportCardAction] = []
        let compact = Self.row(width: 200, pressed: { pressed.append($1) })
        compact.show(Self.two)
        compact.actions[1].performClick(nil)
        #expect(pressed == [.dismiss])
    }

    /// The row follows the interface scale like the front page's other rows: taller, larger type
    /// and icon; the front page hands its scale to the row, also to a row added after a change.
    @Test func theRowFollowsTheInterfaceScale() {
        let row = Self.row()
        row.show(Self.two)
        let title = row.titleLabel.font?.pointSize ?? 0
        row.applyScale(1.5)
        #expect(abs(row.intrinsicContentSize.height - ImportSuggestionRowView.height * 1.5) < 0.5)
        #expect(abs((row.titleLabel.font?.pointSize ?? 0) - title * 1.5) < 0.1)
        row.setFrameSize(NSSize(width: 420, height: row.intrinsicContentSize.height))
        row.layoutSubtreeIfNeeded()
        #expect(abs(row.icon.frame.width - ImportSuggestionRowView.iconSide * 1.5) < 0.5)
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        panel.applyScale(1.25)
        let late = Self.row()
        late.show(Self.two)
        panel.setAccessory(late, applyScale: { [weak late] in late?.applyScale($0) })
        #expect(late.scale == 1.25)
        panel.applyScale(1.5)
        #expect(late.scale == 1.5)
    }

    /// The Chief's front page holds the row in its own column, under the action rows and inside
    /// the panel: nothing floats over the conversation's top.
    @Test func theFrontPageHoldsTheRowUnderItsActions() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let row = Self.row()
        row.show(Self.two)
        panel.setAccessory(row)
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
        panel.setAccessory(row)
        panel.layoutSubtreeIfNeeded()
        let top = { (view: HomeFirstRunView) in view.convert(view.agent.bounds, from: view.agent).minY }
        #expect(abs(top(plain) - top(panel)) < 1)
    }

    /// The row goes when the host takes it away.
    @Test func clearingTheAccessoryRemovesTheRow() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 700))
        let row = Self.row()
        row.show(Self.two)
        panel.setAccessory(row)
        panel.setAccessory(nil)
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
