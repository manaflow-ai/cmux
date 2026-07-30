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
