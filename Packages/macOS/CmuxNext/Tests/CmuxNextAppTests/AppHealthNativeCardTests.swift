import AppKit
@testable import CmuxNextAppHealth
import CmuxNextControl
@testable import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// App health's card is the native cmux dialog card, never a web page (Lawrence 2026-11-17: "agent chat needs repair
/// dialog stuck here… most dialogs should have 0 react involved"). The React card drew nothing once the part was
/// healthy again (its popover returns null for a quiet snapshot) and never listened for Escape, so the panel stayed
/// on screen as an empty glass shell that nothing closed.
@MainActor @Suite(.serialized) struct AppHealthNativeCardTests {
    static func snapshot(_ parts: [JSONValue], receipts: [JSONValue] = []) -> JSONValue {
        ["worst": "failed", "parts": .array(parts), "receipts": .array(receipts), "pending": [], "pendingMore": 0]
    }

    static let failed: JSONValue = ["id": "page:7", "kind": "page", "label": "Agent chat", "state": "failed", "sinceMs": 0,
                                    "detail": "Agent chat stopped answering and three reloads did not bring it back.",
                                    "action": "reloadPage", "attempt": 3, "maxAttempts": 3, "nextAtMs": .null, "canRepair": true]

    /// A part that needs a repair: its line as the title, what is wrong, Repair Now (Return) and Done (Escape).
    @Test func aFailedPartReadsAsACardWithRepairNow() {
        let spec = AppHealthCard.spec(Self.snapshot([Self.failed]))
        #expect(spec.title == "Agent chat needs a repair")
        #expect(spec.lines.contains("Agent chat stopped answering and three reloads did not bring it back."))
        #expect(spec.buttons.map(\.id) == ["done", "repair:page:7"])
        #expect(spec.defaultButton?.id == "repair:page:7")
        #expect(spec.cancelButton?.id == "done")
    }

    /// SECURITY of the shell: a quiet snapshot (the part repaired itself) still has words and a Done: the card
    /// is never an empty glass rectangle.
    @Test func aQuietSnapshotStillHasContent() {
        let spec = AppHealthCard.spec(["worst": "healthy", "parts": [], "receipts": [], "pending": [], "pendingMore": 0])
        #expect(!spec.title.isEmpty)
        #expect(spec.buttons.map(\.id) == ["done"])
    }

    /// The card opens native and with its words on the first frame, follows the model, and Escape closes it.
    @Test func theCardShowsAtOnceFollowsTheModelAndEscapeClosesIt() throws {
        let health = AppHealth()
        let popover = AppHealthPopover(health: health)
        popover.open(over: nil)
        defer { popover.close() }
        let panel = try #require(popover.panel)
        #expect(panel.isVisible)
        let card = try #require(panel.dialogView)
        #expect(!card.spec.title.isEmpty)
        #expect(!(panel.contentView.map { Self.views(under: $0) } ?? []).contains { String(describing: type(of: $0)).contains("WebView") },
                "no web view in the card")
        #expect(card.dialog.handle(.escape, modifiers: []))
        #expect(!panel.isVisible, "Escape always closes it")
    }

    /// Done, then the trigger again: the card shows again, with its words (the same snapshot is no reason to skip it).
    @Test func theCardOpensAgainAfterDone() throws {
        let popover = AppHealthPopover(health: AppHealth())
        popover.fixture = AppHealthCard.fixture(state: "failed")
        defer { popover.close() }
        for round in 1...3 {
            popover.open(over: nil)
            let panel = try #require(popover.panel)
            #expect(panel.isVisible, "round \(round): the card shows")
            #expect(panel.dialogView?.spec.title == "Agent chat needs a repair", "round \(round): with its words")
            _ = try #require(panel.dialogView).dialog.press("done")
            #expect(!panel.isVisible, "round \(round): Done closes it")
        }
    }

    static func views(under root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + views(under: $0) } }
}
