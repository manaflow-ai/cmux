import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// A keycap chip inside a dialog button is the Linear-style hint (Lawrence 2026-11-16, picked from the Keycap
/// Playground: variant 2, "Linear kbd"): a small plate, 16 pt tall, with a faint fill and an 11 pt glyph, centred
/// on the button's height 5 pt in from its trailing edge, and concentric with the button (its corner the button's
/// less that inset, never below a visible round floor). Before, every dialog drew the big plate (the button's height
/// less 3 pt, the glyph at the caption size), which read as heavy ("still looks bad"). The keyed button keeps the
/// tab's corner like every other button (a keyed and an unkeyed button side by side match).
@MainActor @Suite(.serialized) struct KeycapChipConcentricTests {
    /// The chip's inset from the button's trailing edge, and from its top and bottom.
    private static var inset: CGFloat { 5 * Typography.userScale }
    /// The chip's height.
    private static var height: CGFloat { 16 * Typography.userScale }
    /// The smallest chip corner that still reads round.
    private static let floor: CGFloat = 2

    private static func laidOut(_ role: CmuxDialogButton.Role, _ hint: CmuxDialogKeyHint, keycap: Bool = true) throws -> (CmuxDialogButtonView, CmuxDialogKeycapView?) {
        // The init every cmux dialog card uses (``CmuxDialogView``).
        let button = CmuxDialogButtonView(CmuxDialogButton(id: "quit", title: "Quit", role: role), hint: hint, keycap: keycap,
                                          target: nil, action: NSSelectorFromString("press:"))
        // Laid out as a dialog lays it out (no extra pass on the chip): the corner it draws is the one on screen.
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()
        return (button, button.subviews.first { $0.identifier?.rawValue == "cmux.dialog.keycap.quit" } as? CmuxDialogKeycapView)
    }

    @Test(arguments: [CmuxDialogKeyHint.escape, .return])
    func theChipIsConcentricWithItsButton(hint: CmuxDialogKeyHint) throws {
        let (button, found) = try Self.laidOut(.cancel, hint)
        let chip = try #require(found)
        let outer = try #require(button.layer).cornerRadius
        let radius = try #require(chip.layer).cornerRadius
        // The geometry (insets) against the shared rule; the corner below, since a dense button's corner less the inset
        // can fall under the round floor (6 - 5 = 1 at compact), where the chip keeps the floor.
        let broken = ConcentricContainer.violations(child: chip.frame, childRadius: max(outer - Self.inset, 0), in: button.bounds,
                                                    outerRadius: outer, padding: Self.inset)
        #expect(broken.isEmpty, "the \(hint.glyph) chip \(chip.frame) r\(radius) in \(button.bounds) r\(outer): \(broken)")
        #expect(abs(radius - max(outer - Self.inset, Self.floor)) <= 0.5, "the \(hint.glyph) chip rounds at \(radius) in a r\(outer) button")
    }

    /// The Linear-style hint: a 16 pt plate, a faint fill, an 11 pt glyph.
    @Test(arguments: [CmuxDialogKeyHint.escape, .return])
    func theChipIsTheSmallLinearHint(hint: CmuxDialogKeyHint) throws {
        let (button, found) = try Self.laidOut(.default, hint)
        let chip = try #require(found)
        #expect(chip.style == .linearKbd)
        #expect(abs(chip.frame.height - Self.height) <= 0.5, "the \(hint.glyph) chip is \(chip.frame.height) pt tall")
        #expect(abs(chip.frame.midY - button.bounds.midY) <= 0.5, "the \(hint.glyph) chip is off the button's centre")
        #expect(abs((chip.label.font?.pointSize ?? 0) - 11 * Typography.userScale) <= 0.5,
                "the \(hint.glyph) glyph is \(chip.label.font?.pointSize ?? 0) pt")
    }

    /// A keyed button and an unkeyed one side by side match: the tab's corner and one height.
    @Test func aKeyedButtonMatchesAnUnkeyedOne() throws {
        let (keyed, _) = try Self.laidOut(.default, .return)
        let (plain, _) = try Self.laidOut(.default, .return, keycap: false)
        #expect(keyed.layer?.cornerRadius == Metrics.buttonCornerRadius)
        #expect(keyed.layer?.cornerRadius == plain.layer?.cornerRadius)
        #expect(keyed.bounds.height == plain.bounds.height, "keyed \(keyed.bounds.height) pt, unkeyed \(plain.bounds.height) pt")
    }
}
