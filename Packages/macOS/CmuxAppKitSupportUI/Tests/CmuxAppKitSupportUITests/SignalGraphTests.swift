import Testing
@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct SignalGraphTests {
    @Test func effectsTrackReadsAndIgnoreEqualWrites() {
        let graph = SignalGraph()
        let count = graph.createSignal(0)
        var observedValues: [Int] = []
        let effect = graph.createEffect { _ in
            observedValues.append(count.get())
        }

        count.set(1)
        count.set(1)
        count.update { $0 + 1 }

        #expect(observedValues == [0, 1, 2])
        withExtendedLifetime(effect) {}
    }

    @Test func effectsReplaceConditionalDependencies() {
        let graph = SignalGraph()
        let usePrimary = graph.createSignal(true)
        let primary = graph.createSignal("primary")
        let fallback = graph.createSignal("fallback")
        var observedValues: [String] = []
        let effect = graph.createEffect { _ in
            observedValues.append(usePrimary.get() ? primary.get() : fallback.get())
        }

        fallback.set("ignored")
        usePrimary.set(false)
        primary.set("also ignored")
        fallback.set("visible")

        #expect(observedValues == ["primary", "ignored", "visible"])
        withExtendedLifetime(effect) {}
    }

    @Test func batchCoalescesMemoAndEffectWork() {
        let graph = SignalGraph()
        let left = graph.createSignal(1)
        let right = graph.createSignal(2)
        var memoRuns = 0
        let sum = graph.createMemo {
            memoRuns += 1
            return left.get() + right.get()
        }
        var observedValues: [Int] = []
        let effect = graph.createEffect { _ in
            observedValues.append(sum.get())
        }

        graph.batch {
            left.set(3)
            right.set(4)
        }

        #expect(memoRuns == 2)
        #expect(observedValues == [3, 7])
        withExtendedLifetime(effect) {}
    }

    @Test func unchangedMemoValueDoesNotRunDownstreamEffect() {
        let graph = SignalGraph()
        let count = graph.createSignal(0)
        let isEven = graph.createMemo { count.get().isMultiple(of: 2) }
        var effectRuns = 0
        let effect = graph.createEffect { _ in
            _ = isEven.get()
            effectRuns += 1
        }

        count.set(2)
        count.set(3)

        #expect(effectRuns == 2)
        withExtendedLifetime(effect) {}
    }

    @Test func diamondDependencyRunsEffectOncePerWrite() {
        let graph = SignalGraph()
        let source = graph.createSignal(1)
        let doubled = graph.createMemo { source.get() * 2 }
        var observedValues: [(Int, Int)] = []
        let effect = graph.createEffect { _ in
            observedValues.append((source.get(), doubled.get()))
        }

        source.set(2)

        #expect(observedValues.count == 2)
        #expect(observedValues.last?.0 == 2)
        #expect(observedValues.last?.1 == 4)
        withExtendedLifetime(effect) {}
    }

    @Test func layeredDiamondsSettleEachMemoOncePerBatch() {
        var duplicateSettlements = 0

        // ObjectIdentifier-backed dictionary iteration is deliberately not a
        // topological order. Exercise enough independent diamonds to prove the
        // scheduler, rather than one lucky hash ordering, owns settlement.
        for _ in 0..<200 {
            let graph = SignalGraph()
            let source = graph.createSignal(1)
            var leftRuns = 0
            var rightRuns = 0
            var combinedRuns = 0
            let left = graph.createMemo {
                leftRuns += 1
                return source.get() * 2
            }
            let right = graph.createMemo {
                rightRuns += 1
                return source.get() + 3
            }
            let combined = graph.createMemo {
                combinedRuns += 1
                return left.get() + right.get()
            }
            let effect = graph.createEffect { _ in
                _ = combined.get()
            }

            graph.batch {
                source.set(2)
            }

            #expect(leftRuns == 2)
            #expect(rightRuns == 2)
            if combinedRuns != 2 {
                duplicateSettlements += 1
            }
            withExtendedLifetime(effect) {}
        }

        #expect(duplicateSettlements == 0)
    }

    @Test func cancellingDiamondsDoNotRunDownstreamEffects() {
        var unnecessaryEffectRuns = 0

        for _ in 0..<200 {
            let graph = SignalGraph()
            let source = graph.createSignal(1)
            let positive = graph.createMemo { source.get() }
            let negative = graph.createMemo { -source.get() }
            let sum = graph.createMemo { positive.get() + negative.get() }
            var effectRuns = 0
            let effect = graph.createEffect { _ in
                _ = sum.get()
                effectRuns += 1
            }

            source.set(2)

            if effectRuns != 1 {
                unnecessaryEffectRuns += 1
            }
            #expect(sum.get() == 0)
            withExtendedLifetime(effect) {}
        }

        #expect(unnecessaryEffectRuns == 0)
    }

    @Test func untrackedReadDoesNotBecomeAnEffectDependency() {
        let graph = SignalGraph()
        let tracked = graph.createSignal(0)
        let incidental = graph.createSignal(0)
        var effectRuns = 0
        let effect = graph.createEffect { _ in
            _ = tracked.get()
            _ = graph.untrack { incidental.get() }
            effectRuns += 1
        }

        incidental.set(1)
        #expect(effectRuns == 1)

        tracked.set(1)
        #expect(effectRuns == 2)
        withExtendedLifetime(effect) {}
    }

    @Test func throwingBatchRestoresPropagation() {
        enum TestError: Error {
            case expected
        }

        let graph = SignalGraph()
        let value = graph.createSignal(0)
        var observedValues: [Int] = []
        let effect = graph.createEffect { _ in
            observedValues.append(value.get())
        }

        do {
            try graph.batch {
                value.set(1)
                throw TestError.expected
            }
        } catch TestError.expected {
            // The batch must flush and restore its nesting depth on error.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        value.set(2)

        #expect(observedValues == [0, 1, 2])
        withExtendedLifetime(effect) {}
    }

    @Test func cleanupRunsBeforeRerunAndOnDispose() {
        let graph = SignalGraph()
        let value = graph.createSignal(0)
        var cleanupValues: [Int] = []
        let effect = graph.createEffect { context in
            let capturedValue = value.get()
            context.onCleanup {
                cleanupValues.append(capturedValue)
            }
        }

        value.set(1)
        effect.dispose()
        value.set(2)

        #expect(cleanupValues == [0, 1])
    }
}
