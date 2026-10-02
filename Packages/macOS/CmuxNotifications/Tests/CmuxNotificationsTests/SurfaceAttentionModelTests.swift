import Foundation
import Testing
@testable import CmuxNotifications

@Suite("Surface attention model")
struct SurfaceAttentionModelTests {
    @MainActor
    @Test("Mutations publish only changed keyed state")
    func mutationsPublishOnlyChangedKeyedState() {
        let surfaceID = UUID()
        let model = SurfaceAttentionModel()
        let recorder = SidebarUnreadValueRecorder<Set<UUID>>()
        let observation = model.observeChanges(owner: recorder) { recorder, surfaceIds in
            recorder.values.append(surfaceIds)
        }
        defer { observation.cancel() }

        #expect(model.setAttention(true, forSurfaceId: surfaceID))
        #expect(model.surfaceIds == [surfaceID])
        #expect(recorder.values == [[surfaceID]])
        #expect(!model.setAttention(true, forSurfaceId: surfaceID))
        #expect(recorder.values == [[surfaceID]])
        #expect(model.setAttention(false, forSurfaceId: surfaceID))
        #expect(model.surfaceIds.isEmpty)
        #expect(recorder.values == [[surfaceID], []])
    }

    @MainActor
    @Test("Nested mutation leaves every observer on the latest value")
    func nestedMutationLeavesEveryObserverOnLatestValue() {
        let surfaceID = UUID()
        let model = SurfaceAttentionModel()
        let first = SidebarUnreadValueRecorder<Set<UUID>>()
        let second = SidebarUnreadValueRecorder<Set<UUID>>()
        let receive: @MainActor (
            SidebarUnreadValueRecorder<Set<UUID>>,
            Set<UUID>
        ) -> Void = { recorder, surfaceIds in
            recorder.values.append(surfaceIds)
            if surfaceIds.contains(surfaceID) {
                model.setAttention(false, forSurfaceId: surfaceID)
            }
        }
        let firstObservation = model.observeChanges(owner: first, receive)
        let secondObservation = model.observeChanges(owner: second, receive)
        defer {
            firstObservation.cancel()
            secondObservation.cancel()
        }

        model.setAttention(true, forSurfaceId: surfaceID)

        #expect(first.values.last?.isEmpty == true)
        #expect(second.values.last?.isEmpty == true)
        #expect(model.surfaceIds.isEmpty)
    }

    @MainActor
    @Test("Releasing an observation synchronously stops delivery")
    func releasingObservationSynchronouslyStopsDelivery() {
        let surfaceID = UUID()
        let model = SurfaceAttentionModel()
        let recorder = SidebarUnreadValueRecorder<Set<UUID>>()
        var observation: SurfaceAttentionObservation? = model.observeChanges(
            owner: recorder
        ) { recorder, surfaceIds in
            recorder.values.append(surfaceIds)
        }
        #expect(observation != nil)

        observation = nil
        model.replace(with: [surfaceID])

        #expect(recorder.values.isEmpty)
    }

}
