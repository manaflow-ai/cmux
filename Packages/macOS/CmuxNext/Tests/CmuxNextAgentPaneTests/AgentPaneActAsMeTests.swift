import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// "Computer use can act as me" (``AgentPaneActAsMe``; Leo, 2026-11-02: "imo you guys ought to be able to
/// do a true send type thing... and also wouldn't there be cases where you would indeed want auto control
/// or something?"). Off by default; on only by the person's own click in the consent card (or an
/// administrator's profile); one press turns it off; while on, posted input counts as the person's for
/// Send, Retry and Approve only, and every let-through is logged with its driver.
@Suite(.serialized)
@MainActor
struct AgentPaneActAsMeTests {
    typealias Slow = AgentPaneSlowStartPromptTests

    static let driver = AgentPaneActAsMe.Driver(pid: 4242, path: "/Applications/cmux.app/Contents/Helpers/cua-driver")

    static func gestures(_ grant: AgentPaneActAsMe?, clock: Slow.Clock = Slow.Clock()) -> AgentPaneUserGestures {
        let gestures = AgentPaneUserGestures(now: { clock.now })
        gestures.actAsMe = grant
        return gestures
    }

    @Test func itIsOffByDefault() {
        let grant = AgentPaneActAsMe()
        #expect(!grant.isOn)
        #expect(grant.holder == nil)
        #expect(grant.lets("session/prompt") == nil)
    }

    @Test func postedInputIsRefusedWhileItIsOff() {
        let gestures = Self.gestures(AgentPaneActAsMe())
        gestures.recordPosted(driver: Self.driver)
        #expect(!gestures.consumePosted(for: "session/prompt"))
        #expect(!gestures.consumePosted(for: "_acpmux/queue_approve"))
        #expect(!gestures.consumeForSend(), "a posted key press became the person's gesture")
        #expect(!gestures.consume(), "a posted key press became the person's gesture")
    }

    @Test func whileOnPostedInputGrantsSendRetryAndApproveOnly() {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        for method in AgentPaneActAsMe.covers.sorted() {
            gestures.recordPosted(driver: Self.driver)
            #expect(gestures.consumePosted(for: method), "\(method)")
            #expect(!gestures.consumePosted(for: method), "one posted gesture granted \(method) twice")
        }
        for method in ["_acpmux/permission_respond", "_acpmux/permission_group_respond", "acp.trust.set", "session/set_mode",
                       "session/set_config_option", "_acpmux/harness_enable", "_acpmux/secret_submit", "_acpmux/btw",
                       "_acpmux/agent_login/start", "session/new"] {
            gestures.recordPosted(driver: Self.driver)
            #expect(!gestures.consumePosted(for: method), "the grant reached \(method)")
            #expect(!gestures.consume(), "a posted gesture stood in for the person's on \(method)")
            #expect(!gestures.hasFreshAnswerGesture, "a posted click may answer a permission")
        }
        #expect(AgentPaneActAsMe.covers == ["session/prompt", "_acpmux/queue_approve"])
    }

    @Test func turningItOffRevokesAtOnce() {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        gestures.recordPosted(driver: Self.driver)
        grant.turnOff()
        #expect(!grant.isOn)
        #expect(!gestures.consumePosted(for: "session/prompt"), "a gesture posted before Turn Off still granted")
    }

    @Test func inputPostedWhileOffDoesNotGrantOnceTurnedOn() {
        let grant = AgentPaneActAsMe()
        let gestures = Self.gestures(grant)
        gestures.recordPosted(driver: Self.driver)
        grant.turnOn(.init())
        #expect(!gestures.consumePosted(for: "session/prompt"))
    }

    @Test func aPostedGestureExpires() {
        let clock = Slow.Clock()
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant, clock: clock)
        gestures.recordPosted(driver: Self.driver)
        clock.now += AgentPaneUserGestures.lifetime + 1
        #expect(!gestures.consumePosted(for: "session/prompt"))
    }

    @Test func turningOffHoldsAManagedGrantOffForThisRun() {
        let grant = AgentPaneActAsMe()
        grant.setManaged(true)
        #expect(grant.holder == .managed)
        grant.turnOff()
        #expect(!grant.isOn)
        grant.setManaged(true)
        #expect(!grant.isOn, "a settings reload undid the person's Turn Off")
        grant.turnOn(.init())
        #expect(grant.holder == .person)
    }

    @Test func everyLetThroughIsLoggedWithItsDriver() {
        let grant = AgentPaneActAsMe()
        grant.setManaged(true)
        let gestures = Self.gestures(grant)
        gestures.recordPosted(driver: Self.driver)
        #expect(gestures.consumePosted(for: "_acpmux/queue_approve"))
        #expect(grant.letThroughs == [.init(method: "_acpmux/queue_approve", holder: .managed, driver: Self.driver)])
        gestures.recordPosted(driver: Self.driver)
        #expect(!gestures.consumePosted(for: "acp.trust.set"))
        #expect(grant.letThroughs.count == 1, "a refused frame was logged as let through")
    }

    @Test func thePersonsGrantIsStoredAndReadBack() async {
        let store = AgentPaneActAsMe.Store.memory()
        let first = AgentPaneActAsMe(store: store)
        first.turnOn(.init())
        await Task.yield()
        let later = AgentPaneActAsMe(store: store)
        for _ in 0..<50 where !later.isOn {
            await later.load()
            if !later.isOn { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(later.holder == .person)
        later.turnOff()
        let after = AgentPaneActAsMe(store: store)
        for _ in 0..<50 {
            if !store.read() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await after.load()
        #expect(!after.isOn, "Turn Off did not reach the store")
    }

    @Test func aRefusedPostedSendAsksOnceAndGrantsNothing() {
        let grant = AgentPaneActAsMe()
        var asks = 0
        grant.ask = { asks += 1 }
        let gestures = Self.gestures(grant)
        gestures.recordPosted(driver: Self.driver)
        gestures.noteRefused("session/mode")
        #expect(asks == 0, "only Send, Retry and Approve ask")
        gestures.noteRefused("session/prompt")
        gestures.recordPosted(driver: Self.driver)
        gestures.noteRefused("session/prompt")
        #expect(asks == 1)
        #expect(!grant.isOn)
    }

    // MARK: The relay

    @Test func aPostedSendGoesThroughTheRelayOnlyWhileOn() async throws {
        let pane = try await AgentPaneDelayedSendGestureTests.paneWithChat()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let grant = AgentPaneActAsMe()
        pane.transport.gestures.actAsMe = grant

        pane.transport.gestures.recordPosted(driver: Self.driver)
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 2, promptId: "p-1")]) == .gestureRequired)

        grant.turnOn(.init())
        pane.transport.gestures.recordPosted(driver: Self.driver)
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 3, promptId: "p-2")]) == nil)
        _ = await pane.inbox.frame(containing: #""id":3"#)
        #expect(grant.letThroughs.map(\.method) == ["session/prompt"])

        grant.turnOff()
        pane.transport.gestures.recordPosted(driver: Self.driver)
        #expect(await pane.transport.send(connection: pane.id, frames: [Slow.prompt(id: 4, promptId: "p-3")]) == .gestureRequired)
    }

    @Test func aPostedGestureGivesASendTicketOnlyWhileOn() throws {
        let grant = AgentPaneActAsMe()
        let gestures = Self.gestures(grant)
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        gestures.recordPosted(driver: Self.driver)
        #expect(gestures.reserve(connection: 1, intent: send) == nil)
        grant.turnOn(.init())
        gestures.recordPosted(driver: Self.driver)
        #expect(gestures.reserve(connection: 1, intent: send) != nil)
        let mode = try #require(AgentPaneGestureIntent(gestureParams: [
            "intent": ["method": "session/set_mode", "params": ["modeId": "bypassPermissions"]],
        ]))
        gestures.recordPosted(driver: Self.driver)
        #expect(gestures.reserve(connection: 1, intent: mode) == nil, "a posted gesture reserved a mode")
    }

    /// A Send a driver reserved while the grant was on, then redeemed after the person pressed Turn Off,
    /// is refused, even when the grant was turned on again in between. The person's own ticket still sends.
    @Test func turningItOffVoidsThePostedSendTickets() throws {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        let pick = AgentPaneGesturePick(method: "session/prompt", params: ["_meta": ["acpmux": ["promptId": "p-1"]]])
        gestures.recordPosted(driver: Self.driver)
        let posted = try #require(gestures.reserve(connection: 1, intent: send))
        grant.turnOff()
        #expect(!gestures.redeem(posted, connection: 1, pick: pick), "a posted Send ticket outlived Turn Off")

        // Reserved while on, then off and on again: still void.
        grant.turnOn(.init())
        gestures.recordPosted(driver: Self.driver)
        let beforeOff = try #require(gestures.reserve(connection: 1, intent: send))
        grant.turnOff()
        grant.turnOn(.init())
        #expect(!gestures.redeem(beforeOff, connection: 1, pick: pick), "turning it on again revived a revoked ticket")
        // A ticket reserved under the standing grant sends.
        gestures.recordPosted(driver: Self.driver)
        let standing = try #require(gestures.reserve(connection: 1, intent: send))
        #expect(gestures.redeem(standing, connection: 1, pick: pick))
        // The person's own Send ticket does not depend on the grant.
        gestures.record()
        let own = try #require(gestures.reserve(connection: 1, intent: send))
        grant.turnOff()
        #expect(gestures.redeem(own, connection: 1, pick: pick), "Turn Off voided the person's own Send")
    }

    /// A credential transfer rides on a Send ticket, but the grant never covers it: a posted gesture
    /// cannot reserve one while the grant is on.
    @Test func aPersonOnlyReservationRefusesPostedInput() throws {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        gestures.recordPosted(driver: Self.driver)
        #expect(gestures.reserve(connection: 1, intent: send, paid: false, personOnly: true) == nil,
                "posted input reserved a credential transfer")
        gestures.record()
        #expect(gestures.reserve(connection: 1, intent: send, paid: false, personOnly: true) != nil)
    }

    /// Turn Off pressed before the launch's managed read lands holds the forced grant off.
    @Test func turnOffBeforeTheManagedReadHoldsItOff() {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        grant.turnOff()
        grant.setManaged(true)
        #expect(!grant.isOn, "a managed read that landed after Turn Off turned it back on")
    }

    /// Turn Off pressed while the stored grant is read wins over the read.
    @Test func turnOffDuringTheStoredReadWins() async {
        let (started, reading) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        // A stored grant that is on, read only once Turn Off was pressed.
        let store = AgentPaneActAsMe.Store(read: {
            reading.yield()
            release.wait()
            return true
        }, write: { _ in })
        let grant = AgentPaneActAsMe(store: store)
        let read = Task { await grant.load() }
        for await _ in started { break }
        grant.turnOff()
        release.signal()
        await read.value
        #expect(!grant.isOn, "the launch read undid Turn Off")
    }

    /// A posted Send ticket is logged as let through when its frame redeems it, not when it is reserved.
    @Test func aPostedTicketIsLoggedOnlyWhenRedeemed() throws {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        let send = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        let pick = AgentPaneGesturePick(method: "session/prompt", params: ["_meta": ["acpmux": ["promptId": "p-1"]]])
        gestures.recordPosted(driver: Self.driver)
        let ticket = try #require(gestures.reserve(connection: 1, intent: send))
        #expect(grant.letThroughs.isEmpty, "a reservation was logged as let through")
        #expect(gestures.redeem(ticket, connection: 1, pick: pick))
        #expect(grant.letThroughs == [.init(method: "session/prompt", holder: .person, driver: Self.driver)])
        gestures.recordPosted(driver: Self.driver)
        let unused = try #require(gestures.reserve(connection: 1, intent: send))
        #expect(!gestures.redeem(unused, connection: 2, pick: pick))
        #expect(grant.letThroughs.count == 1, "a refused redemption was logged as let through")
    }

    @Test func aGesturePostedBeforeTurnOffDoesNotGrantOnceTurnedOnAgain() {
        let grant = AgentPaneActAsMe()
        grant.turnOn(.init())
        let gestures = Self.gestures(grant)
        gestures.recordPosted(driver: Self.driver)
        grant.turnOff()
        grant.turnOn(.init())
        #expect(!gestures.consumePosted(for: "session/prompt"))
    }

    // MARK: The consent card

    @Test func theCardsAllowTakesOnlyThePersonsOwnClick() throws {
        _ = NSApplication.shared
        let grant = AgentPaneActAsMe()
        let card = AgentPaneActAsMeCard(grant: grant)
        card.content.rebuild()
        card.setContentSize(card.content.fittingSize)
        card.contentView?.layoutSubtreeIfNeeded()
        card.eventInHand = { nil }
        let allow = try #require(card.content.allow)
        let point = allow.convert(NSPoint(x: allow.bounds.midX, y: allow.bounds.midY), to: nil)
        func click(_ type: NSEvent.EventType, number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 100 + Double(number) / 10,
                               windowNumber: card.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)
        }
        // A posted click (the strict check says not the person's) turns nothing on.
        card.isPersonEvent = { _ in false }
        card.dispatch(try #require(click(.leftMouseDown, number: 1))) {}
        card.dispatch(try #require(click(.leftMouseUp, number: 2))) {}
        #expect(!grant.isOn, "a posted click on Allow turned it on")
        // The button's action (an Accessibility press, a programmatic click) turns nothing on.
        card.content.allowPressed(allow)
        (allow as? NSButton)?.performClick(nil)
        #expect(!grant.isOn, "Allow's action turned it on")
        // The person's own click does.
        card.isPersonEvent = { _ in true }
        card.dispatch(try #require(click(.leftMouseDown, number: 3))) {}
        card.dispatch(try #require(click(.leftMouseUp, number: 4))) {}
        #expect(grant.holder == .person)
    }

    /// The card shows when an agent's Send is refused: a person's click that lands on Allow right then was
    /// meant for something else, and turns nothing on.
    @Test func allowIgnoresAClickRightAfterTheCardShows() throws {
        _ = NSApplication.shared
        let grant = AgentPaneActAsMe()
        let card = AgentPaneActAsMeCard(grant: grant)
        card.content.rebuild()
        card.setContentSize(card.content.fittingSize)
        card.contentView?.layoutSubtreeIfNeeded()
        card.eventInHand = { nil }
        card.isPersonEvent = { _ in true }
        card.shownAt = 100
        let allow = try #require(card.content.allow)
        let point = allow.convert(NSPoint(x: allow.bounds.midX, y: allow.bounds.midY), to: nil)
        func click(_ type: NSEvent.EventType, at time: TimeInterval, number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                               windowNumber: card.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)
        }
        card.dispatch(try #require(click(.leftMouseDown, at: 100.1, number: 1))) {}
        card.dispatch(try #require(click(.leftMouseUp, at: 100.6, number: 2))) {}
        #expect(!grant.isOn, "a click begun as the card appeared turned it on")
        card.dispatch(try #require(click(.leftMouseDown, at: 100.7, number: 3))) {}
        card.dispatch(try #require(click(.leftMouseUp, at: 100.8, number: 4))) {}
        #expect(grant.holder == .person)
    }
}
