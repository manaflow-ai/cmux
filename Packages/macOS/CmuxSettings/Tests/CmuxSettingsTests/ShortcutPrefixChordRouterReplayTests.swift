import Testing
@testable import CmuxSettings

@Suite("Shortcut prefix chord replay routing")
struct ShortcutPrefixChordRouterReplayTests {
    private let prefix = ShortcutStroke(key: "b", control: true)
    private let suffix = ShortcutStroke(key: "n")

    private var binding: ShortcutPrefixChordBinding {
        ShortcutPrefixChordBinding(
            actionID: "newTab",
            firstStroke: prefix,
            secondStroke: suffix,
            label: "New Tab"
        )
    }

    @Test func replayedEventIsResolvedExactlyOnce() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let prefixEvent = ShortcutPrefixChordEventIdentity(
            eventNumber: 100,
            windowID: 3,
            keyCode: 11,
            modifierFlags: controlFlag,
            timestamp: 10
        )
        let first = router.handleOnce(
            stroke: prefix,
            now: 10,
            windowID: 3,
            bindings: [binding],
            eventID: prefixEvent
        )
        let replay = router.handleOnce(
            stroke: prefix,
            now: 10.01,
            windowID: 3,
            bindings: [binding],
            eventID: prefixEvent
        )

        #expect(
            first == .init(
                result: .armed(available: [binding], expiresAt: 10.8),
                wasDuplicate: false
            )
        )
        #expect(replay == .init(result: first.result, wasDuplicate: true))
        #expect(router.isArmed)

        let suffixEvent = ShortcutPrefixChordEventIdentity(
            eventNumber: 101,
            windowID: 3,
            keyCode: 45,
            modifierFlags: 0,
            timestamp: 10.1
        )
        let executed = router.handleOnce(
            stroke: suffix,
            now: 10.1,
            windowID: 3,
            bindings: [binding],
            eventID: suffixEvent
        )
        let executedReplay = router.handleOnce(
            stroke: suffix,
            now: 10.11,
            windowID: 3,
            bindings: [binding],
            eventID: suffixEvent
        )
        #expect(executed == .init(result: .executed(binding), wasDuplicate: false))
        #expect(executedReplay == .init(result: .executed(binding), wasDuplicate: true))
        #expect(!router.isArmed)
    }

    @Test func distinctEventNumbersDoNotCollapseAutorepeat() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let firstEvent = ShortcutPrefixChordEventIdentity(
            eventNumber: 200,
            keyCode: 11,
            modifierFlags: controlFlag,
            timestamp: 20
        )
        let repeatEvent = ShortcutPrefixChordEventIdentity(
            eventNumber: 201,
            keyCode: 11,
            modifierFlags: controlFlag,
            timestamp: 20
        )
        #expect(
            router.handleOnce(
                stroke: prefix,
                now: 20,
                bindings: [binding],
                eventID: firstEvent
            ).wasDuplicate == false
        )
        // A repeated prefix is a new physical event. It completes the pending
        // chord as a mismatch only when it is not itself the configured suffix;
        // this assertion verifies it is not a replay of the first event.
        #expect(
            router.handleOnce(
                stroke: prefix,
                now: 20.1,
                bindings: [binding],
                eventID: repeatEvent
            ).wasDuplicate == false
        )
    }

    @Test func replayAfterDeadlineCannotKeepRouterArmed() {
        var router = ShortcutPrefixChordRouter(prefix: prefix, timeout: 0.5)
        let event = ShortcutPrefixChordEventIdentity(
            eventNumber: 300,
            windowID: 1,
            keyCode: 11,
            modifierFlags: controlFlag,
            timestamp: 30
        )
        let armed = router.handleOnce(
            stroke: prefix,
            now: 30,
            windowID: 1,
            bindings: [binding],
            eventID: event
        )
        #expect(armed.result == .armed(available: [binding], expiresAt: 30.5))

        let replay = router.handleOnce(
            stroke: prefix,
            now: 30.6,
            windowID: 1,
            bindings: [binding],
            eventID: event
        )
        #expect(replay.wasDuplicate)
        #expect(replay.result == armed.result)
        #expect(!router.isArmed)
    }

    @Test func unsupportedReplayAfterDeadlineCannotKeepRouterArmed() {
        var router = ShortcutPrefixChordRouter(prefix: prefix, timeout: 0.5)
        let prefixEvent = ShortcutPrefixChordEventIdentity(
            eventNumber: 301,
            windowID: 1,
            keyCode: 11,
            modifierFlags: controlFlag,
            timestamp: 31
        )
        let armed = router.handleOnce(
            stroke: prefix,
            now: 31,
            windowID: 1,
            bindings: [binding],
            eventID: prefixEvent
        )
        #expect(armed.result == .armed(available: [binding], expiresAt: 31.5))

        // A system-defined event can be replayed through a later AppKit seam.
        // It returns the recorded decision, but cannot preserve live state.
        let unsupportedReplay = router.handleUnsupportedOnce(
            now: 31.6,
            windowID: 1,
            eventID: prefixEvent
        )
        #expect(unsupportedReplay == .init(result: armed.result, wasDuplicate: true))
        #expect(!router.isArmed)
    }

    @Test func prefixInNewWindowRearmsWithThatWindowTable() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(
            stroke: prefix,
            now: 31,
            windowID: 1,
            bindings: [binding]
        )

        let result = router.handle(
            stroke: prefix,
            now: 31.1,
            windowID: 2,
            bindings: [binding]
        )
        guard case let .armed(available, _) = result else {
            Issue.record("a prefix in a new window should replace the old pending chord")
            return
        }
        #expect(available == [binding])
        #expect(router.pendingWindowID == 2)
    }

    private var controlFlag: UInt { 1 << 18 }
}
