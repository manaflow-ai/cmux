import AppKit
import CmuxNextDesign
import CmuxNextDevices
@testable import CmuxNextMacScreen
import Foundation
import Testing

/// SECURITY: a device asking to see or control this Mac is answered Allow only by the person's own click on
/// one of the two Allow answers (Allow, the hub's Always at the scope asked for, and Allow Only This Time), as the join
/// consent is (``CmuxDialogPersonClick``): no key (Return after a click into the card), no Accessibility press,
/// no programmatic click and no click another process posts reaches an Allow. Escape and any press may Deny.
@MainActor
struct MacScreenApprovalPersonClickTests {
    /// The two Allows of a Full Control request: Allow (Always Allow Full Control) and Allow Only This Time.
    static let allows: [MacScreenApprovalChoice] = [.alwaysFull, .once]

    private static func prompt() -> (MacScreenApprovalPrompt, Recorded) {
        let prompt = MacScreenApprovalPrompt()
        let recorded = Recorded()
        prompt.answerChoice = { recorded.choices.append($0) }
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "iPhone",
                                      viewerKeyFingerprint: String(repeating: "ab", count: 32), scope: .full)])
        return (prompt, recorded)
    }

    final class Recorded { var choices: [MacScreenApprovalChoice] = [] }

    /// Return answers nothing, and no Allow shows a key; Escape still denies.
    @Test func noKeyAllows() throws {
        let (prompt, recorded) = Self.prompt()
        defer { prompt.update([]) }
        let card = try #require(prompt.dialogView)
        for choice in Self.allows {
            #expect(card.spec.buttons.first { $0.id == choice.rawValue }?.personOnly == true, "\(choice)")
            #expect(card.buttonView(choice.rawValue)?.keyHint == nil, "\(choice) shows no key")
        }
        #expect(!card.dialog.handle(.return, modifiers: []))
        #expect(recorded.choices.isEmpty)
        #expect(card.dialog.handle(.escape, modifiers: []))
        #expect(recorded.choices == [.deny])
    }

    /// Only the person's own click on an Allow answers it, once; presses and clicks the check refuses do not.
    @Test func onlyThePersonsOwnClickAllows() throws {
        let (prompt, recorded) = Self.prompt()
        defer { prompt.update([]) }
        let panel = try #require(prompt.approvalPanel)
        let card = try #require(prompt.dialogView)
        let full = try #require(card.buttonView(MacScreenApprovalChoice.alwaysFull.rawValue))
        let once = try #require(card.buttonView(MacScreenApprovalChoice.once.rawValue))
        let deny = try #require(card.buttonView(MacScreenApprovalChoice.deny.rawValue))
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        // Well after the prompt showed, and each click well after the last (the activation delay).
        let base = ProcessInfo.processInfo.systemUptime + 60
        var number = 0
        let event = { (type: NSEvent.EventType, at: NSPoint) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: base + TimeInterval(number) * 5,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
        }
        var genuine: Set<Int> = []
        prompt.isPersonEvent = { genuine.contains($0.eventNumber) }
        var current: NSEvent?
        prompt.eventInHand = { current }
        let click = { (on: NSView, person: Bool, inside: () -> Void) throws in
            let pressed = try event(.leftMouseDown, center(on)), released = try event(.leftMouseUp, center(on))
            if person { genuine.formUnion([pressed.eventNumber, released.eventNumber]) }
            current = pressed
            panel.dispatch(pressed) {
                current = released
                inside()
            }
        }
        _ = full.accessibilityPerformPress()
        full.performClick(nil)
        try click(full, false) { full.performClick(nil) } // a posted click the check refuses
        try click(deny, true) { _ = once.accessibilityPerformPress() } // a press inside the person's click on Deny
        #expect(recorded.choices.isEmpty)
        try click(full, true) { full.performClick(nil) }
        #expect(recorded.choices == [.alwaysFull])
        try click(deny, true) { deny.performClick(nil) }
        #expect(recorded.choices == [.alwaysFull, .deny], "any press denies")
    }
}
