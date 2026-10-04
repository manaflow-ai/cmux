import AppKit
import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation
import Testing
@testable import CmuxNextBrowserHost

/// Review fixes (c3 review, browser lead v4): a person's input pauses a
/// lease once per event and driver input never does; a closed relay answers
/// its pending commands; ids the app did not announce are refused and never
/// marked; a malformed frame does not end the link; waits end on cancel.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserHostProviderReviewTests {
    static func key(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
    }

    static func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func onlyAPersonsKeyDownsAndClicksPauseALease() {
        #expect(ProviderUserInput.pausesLease(Self.key(.keyDown)))
        #expect(ProviderUserInput.pausesLease(Self.mouse(.leftMouseDown)))
        #expect(ProviderUserInput.pausesLease(Self.mouse(.rightMouseDown)))
        // One frame per press: releases and drags do not count again.
        #expect(!ProviderUserInput.pausesLease(Self.key(.keyUp)))
        #expect(!ProviderUserInput.pausesLease(Self.mouse(.leftMouseUp)))
        #expect(!ProviderUserInput.pausesLease(Self.mouse(.leftMouseDragged)))
        #expect(!ProviderUserInput.pausesLease(Self.mouse(.mouseMoved)))
    }

    @Test func driverInputOnALeasedTabSendsNoUserInput() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit)])
        let (host, _) = await h.connected()
        host.ack()
        host.send(.lease(targetID: "w1", lease: ProviderLease(session: "s", actor: "agent", origin: "cli", label: "L", sinceMs: 1)))
        host.send(.call(id: 1, method: "input.key", params: .object(["targetId": .string("w1"), "type": .string("down"), "key": .string("a")])))
        host.send(.call(id: 2, method: "tabs.list", params: .object([:])))
        // Only the two results: driver input is not a person's input.
        #expect(await host.next() == .result(id: 1, result: .null, error: nil))
        #expect(await host.next() == .result(id: 2, result: .null, error: nil))
        #expect(h.provider.reportUserInput(event: Self.key(.keyUp), targetID: "w1") == false)
        #expect(h.provider.reportUserInput(event: Self.key(.keyDown), targetID: "w1"))
        #expect(await host.next() == .userInput(targetID: "w1"))
    }

    @Test func aRelayThatClosesAnswersItsPendingCommandsFirst() async throws {
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        h.relay.echoes = false
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()
        host.send(.cdpAttach(targetID: "c1"))
        host.send(.cdp(targetID: "c1", message: #"{"id":5,"method":"Runtime.evaluate","sessionId":"S"}"#))
        // The relay started and sent the command; no reply comes.
        #expect(await h.relay.sentQueue.next() == #"{"id":1073741824,"method":"Runtime.evaluate","sessionId":"S"}"#)
        h.relay.onEnd?()
        guard case .cdp("c1", let reply)? = await host.next() else {
            Issue.record("expected an error reply for the pending command")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        #expect(object["id"] as? Int == 5)
        #expect(object["sessionId"] as? String == "S")
        #expect(object["error"] != nil)
        #expect(await host.next() == .event(name: "tab.relay.closed", payload: .object(["targetId": .string("c1")])))
    }

    @Test func idsTheAppDidNotAnnounceAreRefusedAndNeverMarked() async throws {
        // inc1 is an incognito tab: the tab source never lists it.
        let h = ProviderHarness(tabs: [tab("c1", .cef)])
        let (host, _) = await h.connected()
        _ = await host.next() // tab.access
        host.ack()
        host.send(.cdpAttach(targetID: "inc1"))
        host.send(.cdp(targetID: "inc1", message: #"{"id":1,"method":"Target.getTargetInfo"}"#))
        guard case .cdp("inc1", let reply)? = await host.next() else {
            Issue.record("expected a cdp error reply")
            return
        }
        #expect(reply.contains("error"))
        host.send(.lease(targetID: "inc1", lease: ProviderLease(session: "s", actor: "agent", origin: "cli", label: "L", sinceMs: 1)))
        host.send(.call(id: 2, method: "tab.info", params: .object(["targetId": .string("inc1")])))
        guard case .result(2, nil, .object(let error)?)? = await host.next() else {
            Issue.record("expected an error result")
            return
        }
        #expect(error["code"] == .string("not_found"))
        #expect(h.provider.leases["inc1"] == nil)
        #expect(h.marking.marked.isEmpty)
        #expect(h.relay.prepared.isEmpty)
    }

    @Test func aMalformedFrameIsDroppedAndTheLinkStays() async throws {
        let h = ProviderHarness(tabs: [tab("w1", .webkit)])
        let (host, _) = await h.connected()
        host.ack()
        host.sendRaw(#"{"t":"cdp","targetId":"w1"}"#)
        host.send(.call(id: 3, method: "tabs.list", params: .object([:])))
        #expect(await host.next() == .result(id: 3, result: .null, error: nil))
    }

    @Test func aOneShotWaitEndsOnCancelOrResolve() async {
        let cancelled = OneShot<Bool>()
        let waiting = Task { await cancelled.wait(cancelled: false) }
        waiting.cancel()
        #expect(await waiting.value == false)

        let early = OneShot<Bool>()
        early.resolve(true)
        early.resolve(false)
        #expect(await early.wait(cancelled: false) == true)
    }
}
