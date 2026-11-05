import AppKit
@testable import CmuxNextServer
import CmuxNextTestSupport
import Testing

/// SECURITY: the Pair Another Machine card's Confirm pairs a machine into the person's account, so
/// it answers only the person's own click on it, read by the panel from the click's events (the
/// join consent sheet's ``CmuxDialogPersonClick``): no Accessibility press, programmatic click,
/// Return key, or click another process posts approves, nor a click begun right after Confirm
/// appeared. Then the person's click approves, once, through Add Server's own approve.
@MainActor @Suite(.serialized) struct PairInviteConfirmTests {
    private func approvals(_ source: MockServerSource) -> [ServerIntentKind] {
        source.received.map(\.kind).filter { if case .approveCode = $0 { true } else { false } }
    }

    /// A card whose invite a machine used: Confirm shows.
    private func arrivedCard(_ source: MockServerSource, isPerson: @escaping @MainActor (NSEvent) -> Bool) async throws -> PairInviteCardPanel {
        _ = NSApplication.shared
        let approver = ServerModel(source: source)
        approver.start()
        let now = MockServerScenario.referenceDate
        let model = PairInviteModel(service: .mock(now: now, frames: [.arrived(code: MockServerScenario.offerCode)]), approver: approver,
                                    clock: { now }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        let card = PairInviteCardPanel(model: model)
        card.isPersonEvent = isPerson
        await model.mint()
        for _ in 0..<1000 where card.content.confirmButton == nil { await Task.yield() }
        try #require(card.content.confirmButton != nil, "Confirm shows once the machine arrived")
        card.setFrame(NSRect(x: 0, y: 0, width: PairInviteView.width, height: card.content.fittingSize.height), display: true)
        card.orderFrontRegardless()
        card.content.layoutSubtreeIfNeeded()
        return card
    }

    @Test func noKeyPressOrPostedClickConfirms() async throws {
        let source = MockServerSource()
        let card = try await arrivedCard(source, isPerson: { _ in false })
        defer { card.model.close(); card.closeAfterTest() }
        let confirm = try #require(card.content.confirmButton)
        #expect(confirm.isEnabled)
        _ = confirm.accessibilityPerformPress()
        confirm.performClick(nil)
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                      windowNumber: card.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        card.dispatch(returnKey) {}
        #expect(card.model.perform(.confirm) == false)
        for _ in 0..<50 { await Task.yield() }
        #expect(approvals(source).isEmpty, "an Accessibility press, a programmatic click, Return and perform approve nothing")
    }

    @Test func onlyThePersonsOwnSettledClickOnConfirmApproves() async throws {
        let source = MockServerSource()
        var genuine: Set<Int> = []
        let card = try await arrivedCard(source, isPerson: { genuine.contains($0.eventNumber) })
        defer { card.model.close(); card.closeAfterTest() }
        let confirm = try #require(card.content.confirmButton)
        let cancel = try #require(Self.find(card.contentView, id: "cmux.pairInvite.button.cancel"))
        let delay = card.personClick.activationDelay
        #expect(delay >= 0.2, "a click aimed at what was there before Confirm appeared is not taken")
        let base = ProcessInfo.processInfo.systemUptime + 1000
        card.personClick.shown(at: base)
        let center = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        var number = 0
        let event = { (type: NSEvent.EventType, at: NSPoint, time: TimeInterval) throws -> NSEvent in
            number += 1
            return try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: time,
                                                   windowNumber: card.windowNumber, context: nil, eventNumber: number,
                                                   clickCount: 1, pressure: 0))
        }
        var current: NSEvent?
        card.eventInHand = { current }
        /// A click begun at `time`: the mouse-down on `down`, the mouse-up on `up` inside its dispatch.
        let click = { (down: NSView, up: NSView, person: Bool, time: TimeInterval) throws in
            let pressed = try event(.leftMouseDown, center(down), time), released = try event(.leftMouseUp, center(up), time + 0.05)
            if person { genuine.formUnion([pressed.eventNumber, released.eventNumber]) }
            current = pressed
            card.dispatch(pressed) {
                current = released
                confirm.performClick(nil)
            }
        }
        try click(confirm, confirm, true, base + delay / 2) // right after Confirm appeared
        try click(confirm, confirm, false, base + 4 * delay) // another process's posted click
        try click(confirm, cancel, true, base + 8 * delay) // pressed on Confirm, released on Cancel
        try click(cancel, confirm, true, base + 12 * delay) // pressed on Cancel, released on Confirm
        for _ in 0..<50 { await Task.yield() }
        #expect(approvals(source).isEmpty, "no click so far approves")
        try click(confirm, confirm, true, base + 16 * delay)
        #expect(approvals(source) == [.approveCode(code: MockServerScenario.offerCode, team: "team_personal", name: "build-01",
                                                   placeChief: MockServerScenario.candidate.isChiefBrain)],
                "the person's click approves once, through Add Server's approve")
    }

    private static func find(_ view: NSView?, id: String) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = find(child, id: id) { return found } }
        return nil
    }
}
