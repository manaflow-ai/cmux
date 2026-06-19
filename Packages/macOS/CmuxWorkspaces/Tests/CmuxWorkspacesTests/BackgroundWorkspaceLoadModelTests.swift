import Foundation
import Observation
import Testing
@testable import CmuxWorkspaces

/// Pins the Observation contract the retired `@Published`
/// `pendingBackgroundWorkspaceLoadIds` / `mountedBackgroundWorkspaceLoadIds` /
/// `debugPinnedWorkspaceLoadIds` / `isWorkspaceCycleHot` bridges were replaced
/// with: `withObservationTracking.onChange` fires once per genuine change
/// (matching the migrated app subscribers), and the model stores plain values.
/// Thread-safe-enough counter for the synchronous `onChange` closures here:
/// every mutation runs on the test MainActor (the model is `@MainActor`), so
/// the only reason this is a class is to be captured by a `@Sendable` closure.
private final class FireCounter: @unchecked Sendable {
    var count = 0
}

@MainActor
@Suite struct BackgroundWorkspaceLoadModelTests {
    @Test func startsEmpty() {
        let model = BackgroundWorkspaceLoadModel()
        #expect(model.pendingBackgroundWorkspaceLoadIds.isEmpty)
        #expect(model.mountedBackgroundWorkspaceLoadIds.isEmpty)
        #expect(model.debugPinnedWorkspaceLoadIds.isEmpty)
        #expect(model.isWorkspaceCycleHot == false)
    }

    @Test func observationFiresOnPendingChange() {
        let model = BackgroundWorkspaceLoadModel()
        let counter = FireCounter()
        withObservationTracking {
            _ = model.pendingBackgroundWorkspaceLoadIds
        } onChange: {
            counter.count += 1
        }
        model.pendingBackgroundWorkspaceLoadIds = [UUID()]
        #expect(counter.count == 1)
    }

    @Test func observationFiresOnCycleHotChange() {
        let model = BackgroundWorkspaceLoadModel()
        let counter = FireCounter()
        withObservationTracking {
            _ = model.isWorkspaceCycleHot
        } onChange: {
            counter.count += 1
        }
        model.isWorkspaceCycleHot = true
        #expect(counter.count == 1)
    }

    @Test func independentPropertiesTrackIndependently() {
        let model = BackgroundWorkspaceLoadModel()
        let counter = FireCounter()
        withObservationTracking {
            _ = model.pendingBackgroundWorkspaceLoadIds
        } onChange: {
            counter.count += 1
        }
        // Mutating an unrelated property must not trip the pending observer.
        model.mountedBackgroundWorkspaceLoadIds = [UUID()]
        #expect(counter.count == 0)
    }
}
