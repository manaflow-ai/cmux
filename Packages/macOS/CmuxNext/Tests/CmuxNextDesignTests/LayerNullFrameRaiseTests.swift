import Foundation
import os
import QuartzCore
import Testing

/// An inset of a rect smaller than the inset is the null rect, whose origin is infinite. Several
/// `layout()` overrides give such an inset to a layer as its frame. A view that gets an infinite
/// frame only logs a fault. This case shows what Core Animation does for a layer: it sets the null
/// rect as the frame of a new layer below Foundation's Objective-C catch (an archive call reports
/// an exception from `encode(with:)` as an error) and expects that Core Animation raised. The
/// case prints what it saw, for the run's log: the caught error, or the layer's geometry after
/// the set. It runs on a fresh thread of its own and makes no window and no view.
@Suite struct LayerNullFrameRaiseTests {
    @Test func aNullRectAsALayersFrameRaises() async {
        let seen = await onFreshThread { () -> LayerFacts in
            let box = LayerFactsBox()
            let error = archiveError {
                let layer = CALayer()
                layer.frame = .null
                let position = layer.position, bounds = layer.bounds
                box.facts.withLock { $0.geometryAfterSet = "position \(position), bounds \(bounds)" }
            }
            var facts = box.facts.withLock { $0 }
            facts.caught = error
            return facts
        }
        print("LayerNullFrameRaiseTests: caught \(seen.caught ?? "nothing"); after the set: \(seen.geometryAfterSet ?? "not reached")")
        #expect(seen.caught != nil, "Core Animation did not raise for a null frame: \(seen.geometryAfterSet ?? "the set did not return")")
    }
}

/// What the case saw: the error of the archive call, and the layer's geometry if the set returned.
nonisolated private struct LayerFacts: Sendable {
    var caught: String?
    var geometryAfterSet: String?
}

/// The facts of the case, shared between the archive's work and its thread.
nonisolated private final class LayerFactsBox: Sendable {
    let facts = OSAllocatedUnfairLock(initialState: LayerFacts())
}

/// An object whose `encode(with:)` runs `work`, so `work` runs below Foundation's Objective-C catch.
/// The archive writes the class name: a private class needs a fixed Objective-C name.
@objc(CmuxNextRaisingCoderForLayerNullFrameTests)
nonisolated private final class RaisingCoder: NSObject, NSCoding {
    private let work: @Sendable () -> Void

    init(work: @escaping @Sendable () -> Void) {
        self.work = work
        super.init()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func encode(with coder: NSCoder) {
        work()
    }
}

/// Archives an object whose `encode(with:)` runs `work`. Returns the error's text when the archive
/// call caught an Objective-C exception from `work` and reported it as an error; nil when `work`
/// returned.
@inline(never)
nonisolated private func archiveError(_ work: @escaping @Sendable () -> Void) -> String? {
    do {
        _ = try NSKeyedArchiver.archivedData(withRootObject: RaisingCoder(work: work), requiringSecureCoding: false)
        return nil
    } catch {
        return String(describing: error as NSError).prefix(600).description
    }
}

/// Runs `body` on a new thread and returns its result.
nonisolated private func onFreshThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}
