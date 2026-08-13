import Testing
@testable import CmuxSettings

@Suite("Shortcut prefix chord router")
struct ShortcutPrefixChordRouterTests {
    private let prefix = ShortcutStroke(key: "b", control: true)
    private let suffix = ShortcutStroke(key: "n")
    private let otherSuffix = ShortcutStroke(key: "p")

    private var binding: ShortcutPrefixChordBinding {
        ShortcutPrefixChordBinding(
            actionID: "newTab",
            firstStroke: prefix,
            secondStroke: suffix,
            label: "New Tab"
        )
    }

    @Test func prefixPolicyIsStrictAndShared() {
        #expect(
            ShortcutPrefixPolicy().result(for: .unbound) == .unbound
        )
        #expect(
            ShortcutPrefixPolicy().normalized(ShortcutStroke(key: "b")) == nil
        )
        #expect(
            ShortcutPrefixPolicy().normalized(ShortcutStroke(key: "space"))
                == ShortcutStroke(key: "space")
        )
        #expect(
            ShortcutPrefixPolicy().normalized(
                ShortcutStroke(key: "b", control: true, keyCode: 11)
            ) == ShortcutStroke(key: "b", control: true, keyCode: 11)
        )
        #expect(
            ShortcutPrefixPolicy().normalized(
                StoredShortcut(
                    first: ShortcutStroke(key: "b", control: true),
                    second: ShortcutStroke(key: "c")
                )
            ) == nil
        )
        let malformedEmptyPrefix = StoredShortcut(
            first: ShortcutStroke(key: ""),
            second: ShortcutStroke(key: "c")
        )
        #expect(
            ShortcutPrefixPolicy().result(for: malformedEmptyPrefix)
                == .emptyStrokeNotSupported
        )
        #expect(ShortcutPrefixPolicy().normalized(malformedEmptyPrefix) == nil)
        #expect(
            ShortcutPrefixPolicy().normalized(
                ShortcutStroke(key: "media.volumeUp", command: true)
            ) == nil
        )
        #expect(
            ShortcutPrefixPolicy().normalized(
                ShortcutStroke(key: "volumeUp", command: true)
            ) == nil
        )
        #expect(
            ShortcutPrefixPolicy().normalized(
                ShortcutStroke(key: "escape", control: true)
            ) == nil
        )
        #expect(
            ShortcutPrefixPolicy().normalized(ShortcutStroke(key: "")) == nil
        )
    }

    @Test func disabledPrefixNeverConsumesInput() {
        var router = ShortcutPrefixChordRouter()

        #expect(
            router.handle(
                stroke: prefix,
                now: 0,
                bindings: [binding]
            ) == .passThrough
        )
        #expect(
            router.handle(
                stroke: suffix,
                now: 0.1,
                bindings: [binding]
            ) == .passThrough
        )
        #expect(!router.isArmed)
    }

    @Test func prefixArmsOnlyWhenAValidBindingExists() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)

        #expect(
            router.handle(
                stroke: prefix,
                now: 10,
                bindings: [
                    ShortcutPrefixChordBinding(
                        actionID: "other",
                        firstStroke: ShortcutStroke(key: "k", command: true),
                        secondStroke: suffix
                    )
                ]
            ) == .passThrough
        )
        #expect(!router.isArmed)

        guard case let .armed(available, expiresAt) = router.handle(
            stroke: prefix,
            now: 11,
            windowID: 4,
            bindings: [binding]
        ) else {
            Issue.record("expected the configured prefix to arm")
            return
        }
        #expect(available == [binding])
        #expect(expiresAt == 11 + ShortcutPrefixChordRouter.defaultTimeout)
        #expect(router.isArmed)
    }

    @Test func matchingSuffixExecutesAndDisarms() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(stroke: prefix, now: 1, windowID: 7, bindings: [binding])

        #expect(
            router.handle(stroke: suffix, now: 1.2, windowID: 7, bindings: [binding])
                == .executed(binding)
        )
        #expect(!router.isArmed)
    }

    @Test func unmatchedSuffixPassesThroughAndCannotFireSingleAction() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(stroke: prefix, now: 2, windowID: 1, bindings: [binding])

        #expect(
            router.handle(
                stroke: otherSuffix,
                now: 2.1,
                windowID: 1,
                bindings: [binding]
            ) == .mismatchPassThrough
        )
        #expect(!router.isArmed)
    }

    @Test func escapeDisarmsAndIsConsumed() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(stroke: prefix, now: 3, windowID: 1, bindings: [binding])

        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "escape"),
                now: 3.1,
                windowID: 1,
                isEscape: true,
                bindings: [binding]
            ) == .disarmed(consume: true)
        )
        #expect(!router.isArmed)
    }

    @Test func escapeStrokeCancelsEvenWithoutPlatformSentinel() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(stroke: prefix, now: 3.5, windowID: 1, bindings: [binding])

        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "escape"),
                now: 3.6,
                windowID: 1,
                bindings: [binding]
            ) == .disarmed(consume: true)
        )
        #expect(!router.isArmed)
    }

    @Test func timeoutDisarmsOnlyAtDeadline() {
        var router = ShortcutPrefixChordRouter(prefix: prefix, timeout: 0.5)
        _ = router.handle(stroke: prefix, now: 4, bindings: [binding])

        #expect(router.expire(now: 4.49) == nil)
        #expect(router.isArmed)
        #expect(router.expire(now: 4.5) == .disarmed(consume: false))
        #expect(!router.isArmed)
    }

    @Test func pendingChordDoesNotCrossWindows() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        _ = router.handle(stroke: prefix, now: 5, windowID: 1, bindings: [binding])

        #expect(
            router.handle(stroke: suffix, now: 5.1, windowID: 2, bindings: [binding])
                == .passThrough
        )
        #expect(!router.isArmed)
    }

    @Test func duplicateSuffixesFailClosedAndAreNotAdvertised() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let duplicate = ShortcutPrefixChordBinding(
            actionID: "closeTab",
            firstStroke: prefix,
            secondStroke: suffix,
            label: "Close Tab"
        )

        #expect(
            router.handle(
                stroke: prefix,
                now: 6,
                bindings: [binding, duplicate]
            ) == .mismatchPassThrough
        )
        #expect(!router.isArmed)
    }

    @Test func malformedEmptySuffixDoesNotArm() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let malformed = ShortcutPrefixChordBinding(
            actionID: "malformed",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "")
        )

        #expect(
            router.handle(stroke: prefix, now: 6.5, bindings: [malformed])
                == .passThrough
        )
        #expect(!router.isArmed)
        #expect(router.availableBindings.isEmpty)
    }

    @Test func keyCodeDoesNotMakeEquivalentRecordedStrokesAmbiguous() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let recordedPrefix = ShortcutStroke(key: "b", control: true, keyCode: 11)
        let recordedSuffix = ShortcutStroke(key: "n", keyCode: 45)
        let recordedBinding = ShortcutPrefixChordBinding(
            actionID: "newTab",
            firstStroke: recordedPrefix,
            secondStroke: recordedSuffix
        )

        guard case .armed = router.handle(
            stroke: prefix,
            now: 7,
            bindings: [recordedBinding]
        ) else {
            Issue.record("expected canonicalized physical strokes to match")
            return
        }
        #expect(
            router.handle(stroke: suffix, now: 7.1, bindings: [recordedBinding])
                == .executed(recordedBinding)
        )
    }

    @Test func numberedSuffixMatchesTheWholeDigitFamily() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let numbered = ShortcutPrefixChordBinding(
            actionID: "selectWorkspaceByNumber",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "1", command: true),
            matchesNumberedDigits: true
        )

        guard case .armed(let available, _) = router.handle(
            stroke: prefix,
            now: 8,
            bindings: [numbered]
        ) else {
            Issue.record("expected numbered prefix binding to arm")
            return
        }
        #expect(available == [numbered])
        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "7", command: true),
                now: 8.1,
                bindings: [numbered]
            ) == .executed(numbered)
        )
    }

    @Test func numberedSuffixStillFailsClosedWhenAnExactBindingCollides() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let numbered = ShortcutPrefixChordBinding(
            actionID: "selectWorkspaceByNumber",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "1", command: true),
            matchesNumberedDigits: true
        )
        let exact = ShortcutPrefixChordBinding(
            actionID: "otherAction",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "7", command: true)
        )

        guard case .armed = router.handle(
            stroke: prefix,
            now: 9,
            bindings: [numbered, exact]
        ) else {
            Issue.record("the numbered binding should remain available for disjoint digits")
            return
        }
        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "7", command: true),
                now: 9.1,
                bindings: [numbered, exact]
            ) == .mismatchPassThrough
        )
        #expect(!router.isArmed)
    }

    @Test func numberedSuffixWinsForDisjointDigitsAfterAnExactCollision() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let numbered = ShortcutPrefixChordBinding(
            actionID: "selectWorkspaceByNumber",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "1", command: true),
            matchesNumberedDigits: true
        )
        let exact = ShortcutPrefixChordBinding(
            actionID: "otherAction",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "7", command: true)
        )

        _ = router.handle(stroke: prefix, now: 9.5, bindings: [numbered, exact])
        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "8", command: true),
                now: 9.6,
                bindings: [numbered, exact]
            ) == .executed(numbered)
        )
    }

    @Test func onePriorityBindingWinsAnExactCollision() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let ordinary = ShortcutPrefixChordBinding(
            actionID: "ordinary",
            firstStroke: prefix,
            secondStroke: suffix
        )
        let priority = ShortcutPrefixChordBinding(
            actionID: "priority",
            firstStroke: prefix,
            secondStroke: suffix,
            hasPriorityRouting: true
        )

        guard case let .armed(available, _) = router.handle(
            stroke: prefix,
            now: 10,
            bindings: [ordinary, priority]
        ) else {
            Issue.record("a unique priority binding should arm")
            return
        }
        #expect(available == [priority])
        #expect(
            router.handle(stroke: suffix, now: 10.1, bindings: [ordinary, priority])
                == .executed(priority)
        )
    }

    @Test func twoPriorityBindingsStillFailClosed() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let first = ShortcutPrefixChordBinding(
            actionID: "priorityA",
            firstStroke: prefix,
            secondStroke: suffix,
            hasPriorityRouting: true
        )
        let second = ShortcutPrefixChordBinding(
            actionID: "priorityB",
            firstStroke: prefix,
            secondStroke: suffix,
            hasPriorityRouting: true
        )

        #expect(
            router.handle(stroke: prefix, now: 10.5, bindings: [first, second])
                == .mismatchPassThrough
        )
        #expect(!router.isArmed)
    }

    @Test func priorityNumberedBindingWinsOnlyItsOverlappingDigitFamily() {
        var router = ShortcutPrefixChordRouter(prefix: prefix)
        let numbered = ShortcutPrefixChordBinding(
            actionID: "numbered",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "1", command: true),
            matchesNumberedDigits: true,
            hasPriorityRouting: true
        )
        let ordinary = ShortcutPrefixChordBinding(
            actionID: "ordinary",
            firstStroke: prefix,
            secondStroke: ShortcutStroke(key: "7", command: true)
        )

        _ = router.handle(stroke: prefix, now: 11, bindings: [numbered, ordinary])
        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "7", command: true),
                now: 11.1,
                bindings: [numbered, ordinary]
            ) == .executed(numbered)
        )

        _ = router.handle(stroke: prefix, now: 11.2, bindings: [numbered, ordinary])
        #expect(
            router.handle(
                stroke: ShortcutStroke(key: "8", command: true),
                now: 11.3,
                bindings: [numbered, ordinary]
            ) == .executed(numbered)
        )
    }

    @Test func disablingAnAlreadyDisabledPrefixClearsStalePendingState() {
        var router = ShortcutPrefixChordRouter(prefix: nil)
        // This simulates a host recovering a stale transient state after a
        // settings reload; `setPrefix(nil)` must restore the default-off
        // invariant even though the configured value did not change.
        router.setPrefix(prefix)
        _ = router.handle(stroke: prefix, now: 12, bindings: [binding])
        router.setPrefix(nil)
        router.setPrefix(nil)
        #expect(!router.isArmed)
        #expect(router.availableBindings.isEmpty)
    }

}
