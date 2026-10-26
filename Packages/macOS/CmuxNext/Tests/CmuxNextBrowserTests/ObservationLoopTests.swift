import AppKit
@testable import CmuxNextBrowser
import Foundation
import Observation
import Testing

/// ObservationLoop (p04-input-029): a change renders once, before waiting in a later main run loop
/// pass, with no main-actor task per change; a cancelled loop renders nothing.
@MainActor @Suite(.serialized) struct ObservationLoopTests {
    @MainActor @Observable final class Model {
        var value = 0
    }

    /// The test body is one main-queue job, so a `Task { @MainActor }` hop could not run inside it;
    /// a render in the run loop's before-waiting stage does.
    @Test func changesInOnePassRenderOnceBeforeWaiting() {
        let model = Model()
        var renders: [Int] = []
        let loop = ObservationLoop { renders.append(model.value) }
        #expect(renders == [0], "init renders once")

        for value in 1...100 { model.value = value }
        #expect(renders == [0], "a change rendered in its own turn")
        Self.spin(until: { renders.count > 1 })
        #expect(renders == [0, 100], "100 changes in one turn render once")

        Self.spin(passes: 3)
        #expect(renders == [0, 100], "a pass with no change rendered")

        model.value = 101
        Self.spin(until: { renders.count > 2 })
        #expect(renders == [0, 100, 101], "the render re-armed the loop")

        loop.cancel()
        model.value = 102
        Self.spin(passes: 3)
        #expect(renders == [0, 100, 101], "a cancelled loop rendered")
    }

    private static func spin(passes: Int) {
        for _ in 0..<passes { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
    }

    private static func spin(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 2)
        while !done(), Date() < end { spin(passes: 1) }
    }
}
