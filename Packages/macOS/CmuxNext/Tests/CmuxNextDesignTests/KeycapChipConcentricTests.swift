import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// A keycap chip inside a button is concentric with it (Lawrence 2026-11-15, on the quit dialog's "Cancel esc" and
/// "Quit ↩": the chips had square-ish corners). The keyed button keeps the tab's corner like every other button (a
/// keyed and an unkeyed button side by side match), and the chip sits a small inset in on its top, bottom and
/// trailing side with the button's corner less that inset, never below a visible round floor. Before, the inset was
/// 5 pt: the chip was 8 - 5 = 3 pt at the default density and about 1 pt at compact, so it read square.
@MainActor @Suite(.serialized) struct KeycapChipConcentricTests {
    /// The chip's inset in its button: small enough that the chip keeps a round corner (about 3 pt).
    private static var inset: CGFloat { 3 * Typography.userScale }
    /// The smallest chip corner that still reads round.
    private static let floor: CGFloat = 2

    private static func laidOut(_ role: CmuxDialogButton.Role, _ hint: CmuxDialogKeyHint, keycap: Bool = true) throws -> (CmuxDialogButtonView, NSView?) {
        let button = CmuxDialogButtonView(CmuxDialogButton(id: "quit", title: "Quit", role: role), hint: hint, keycap: keycap,
                                          target: nil, action: NSSelectorFromString("press:"))
        // Laid out as a dialog lays it out (no extra pass on the chip): the corner it draws is the one on screen.
        button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
        button.layoutSubtreeIfNeeded()
        return (button, button.subviews.first { $0.identifier?.rawValue == "cmux.dialog.keycap.quit" })
    }

    @Test(arguments: [CmuxDialogKeyHint.escape, .return])
    func theChipIsConcentricWithItsButton(hint: CmuxDialogKeyHint) throws {
        let (button, found) = try Self.laidOut(.cancel, hint)
        let chip = try #require(found)
        let outer = try #require(button.layer).cornerRadius
        let radius = try #require(chip.layer).cornerRadius
        let broken = ConcentricContainer.violations(child: chip.frame, childRadius: radius, in: button.bounds,
                                                    outerRadius: outer, padding: Self.inset)
        #expect(broken.isEmpty, "the \(hint.glyph) chip \(chip.frame) r\(radius) in \(button.bounds) r\(outer): \(broken)")
        #expect(abs(radius - max(outer - Self.inset, Self.floor)) <= 0.5, "the \(hint.glyph) chip rounds at \(radius) in a r\(outer) button")
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
