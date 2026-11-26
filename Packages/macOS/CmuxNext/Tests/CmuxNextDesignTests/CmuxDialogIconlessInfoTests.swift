import AppKit
import CmuxNextDesignTokens
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// A card the person opened (Add Machine) with no icon column, its explainer on an info circle, dragged like a
/// window. Leo: "stupid ... call to have a symbol making space for ABSOLUTLEY NOTHING", "it pops up looking like a
/// window and you can't drag it around like one", "THERE ARE HOVERS AND QUESTION MARK CIRCLES AND INFO CIRCLES".
@MainActor
struct CmuxDialogIconlessInfoTests {
    private static let spec = CmuxDialogSpec(
        title: "Add Machine",
        fields: [.text(id: "host", label: nil, initial: "", placeholder: "user@host", secure: false)],
        buttons: [CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel), CmuxDialogButton(id: "add", title: "Add", role: .default)],
        leadsWithIcon: false, info: "Type a host you reach with ssh.")

    private static func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let hit = view as? T, match(hit) { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub, where: match) { return hit }
        }
        return nil
    }

    @Test func aCardThatLeadsWithNoIconDrawsNoIconColumn() {
        #expect(CmuxDialogView.icon(for: Self.spec) == nil)
        var withIcon = Self.spec
        withIcon.leadsWithIcon = true
        #expect(CmuxDialogView.icon(for: withIcon) != nil)
        let card = CmuxDialogView(dialog: .standalone(Self.spec, activeLook: nil, onPress: { _ in }))
        card.layoutSubtreeIfNeeded()
        #expect(abs(card.fittingSize.width - CmuxDialogMetrics.width) < 0.5)
    }

    @Test func theInfoShowsOnACircleBesideTheTitleNotAsALine() {
        let card = CmuxDialogView(dialog: .standalone(Self.spec, activeLook: nil, onPress: { _ in }))
        let circle = Self.find(NSImageView.self, in: card) { $0.identifier?.rawValue == "cmux.dialog.info" }
        #expect(circle?.themedToolTip == "Type a host you reach with ssh.")
        let lines = Self.find(NSTextField.self, in: card) { $0.stringValue == "Type a host you reach with ssh." }
        #expect(lines == nil)
    }

    /// The circle follows the title's last word; it never sits at the card's far edge with a gap of nothing between.
    @Test func theCircleSitsRightAfterTheTitle() throws {
        let card = CmuxDialogView(dialog: .standalone(Self.spec, activeLook: nil, onPress: { _ in }))
        card.layoutSubtreeIfNeeded()
        let circle = try #require(Self.find(NSImageView.self, in: card) { $0.identifier?.rawValue == "cmux.dialog.info" })
        let title = try #require(Self.find(NSTextField.self, in: card) { $0.stringValue == "Add Machine" })
        let c = circle.convert(circle.bounds, to: card), t = title.convert(title.bounds, to: card)
        #expect(c.minX >= t.maxX && c.minX - t.maxX < 16)
        #expect(c.maxX < card.bounds.width / 2)
    }

    @Test func aPressOnTheGlassDragsAndAPressOnAFieldOrButtonDoesNot() {
        let panel = CmuxFloatingDialogPanel(identifier: "test.movable")
        panel.isMovableByPerson = true
        let card = panel.show(Self.spec) { _ in }
        defer { panel.hide() }
        panel.contentView?.layoutSubtreeIfNeeded()
        func point(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        let field = Self.find(NSTextField.self, in: card) { $0.isEditable }
        let button = card.buttonView("add")
        let title = Self.find(NSTextField.self, in: card) { $0.stringValue == "Add Machine" }
        #expect(field.map { panel.startsDrag(at: point($0)) } == false)
        #expect(button.map { panel.startsDrag(at: point($0)) } == false)
        #expect(title.map { panel.startsDrag(at: point($0)) } == true)
        #expect(!panel.startsDrag(at: NSPoint(x: 1, y: 1)), "the shadow band lets clicks through")
    }
}
