import Foundation
import Testing

@testable import CmuxMobileAnalytics

private struct FixedConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct AnalyticsEmitterTests {
    private func makeEmitter(
        uploader: RecordingAnalyticsUploader,
        consentEnabled: Bool = true,
        anonymousID: String = "anon-1",
        flushBatchSize: Int = 50
    ) -> AnalyticsEmitter {
        AnalyticsEmitter(
            uploader: uploader,
            consent: FixedConsent(isTelemetryEnabled: consentEnabled),
            anonymousID: anonymousID,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            flushBatchSize: flushBatchSize
        )
    }

    @Test func captureBuffersAndExplicitFlushUploads() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader)
        emitter.capture("ios_app_launched", ["launch_type": .string("cold")])
        await emitter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == "ios_app_launched")
        #expect(events.first?.properties["launch_type"] == .string("cold"))
    }

    @Test func consentDisabledDropsEverything() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, consentEnabled: false)
        emitter.capture("ios_terminal_input_submitted", ["byte_count": .int(12)])
        await emitter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.isEmpty)
    }

    @Test func batchSizeTriggersAutomaticFlush() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, flushBatchSize: 3)
        for index in 0..<3 {
            emitter.capture("ios_event_\(index)", [:])
        }
        // The third capture crosses the batch threshold and schedules a drain.
        // flush() awaits the in-flight drain rather than racing it.
        await emitter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.count == 3)
    }

    @Test func superPropertiesMergeOntoEachEvent() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader)
        emitter.setSuperProperties(["app_version": .string("1.2.3")])
        emitter.capture("ios_app_launched", ["launch_type": .string("cold")])
        await emitter.flush()
        let event = await uploader.uploadedEvents.first
        #expect(event?.properties["app_version"] == .string("1.2.3"))
        #expect(event?.properties["launch_type"] == .string("cold"))
    }

    @Test func identifyForwardsUserAndAnonymousIDs() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, anonymousID: "anon-42")
        emitter.identify(userId: "user-7", alias: nil, properties: [:])
        // identify awaits the uploader inside the actor; flush ensures ordering.
        await emitter.flush()
        let calls = await uploader.identifyCalls
        #expect(calls.count == 1)
        #expect(calls.first?.userID == "user-7")
        #expect(calls.first?.anonymousID == "anon-42")
    }

    @Test func anonymousEventsCarryAnonymousIDAndNoUserDistinctID() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, anonymousID: "anon-9")
        emitter.capture("ios_app_first_launch", [:])
        await emitter.flush()
        let event = await uploader.uploadedEvents.first
        // Pre-auth: distinct id is the anonymous id, and anonymousID is folded in
        // for server-side aliasing once the user identifies.
        #expect(event?.distinctID == "anon-9")
        #expect(event?.anonymousID == nil) // distinct == anon ⇒ no redundant alias
        #expect(event?.wireObject["distinct_id"] as? String == "anon-9")
    }

    @Test func afterIdentifyEventsUseUserDistinctID() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, anonymousID: "anon-9")
        emitter.identify(userId: "user-3", alias: nil, properties: [:])
        emitter.capture("ios_terminal_input_submitted", ["byte_count": .int(4)])
        await emitter.flush()
        let event = await uploader.uploadedEvents.first
        #expect(event?.distinctID == "user-3")
        #expect(event?.anonymousID == "anon-9") // alias preserved post-identify
    }

    @Test func retryLeavesEventsBufferedForNextFlush() async {
        let uploader = RecordingAnalyticsUploader(result: .retry)
        let emitter = makeEmitter(uploader: uploader)
        emitter.capture("ios_app_launched", [:])
        await emitter.flush()
        #expect(await uploader.uploadedBatches.count == 1)
        // Now let the upload succeed: the buffered event ships on the next flush.
        await uploader.setResult(.accepted)
        await emitter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.contains { $0.name == "ios_app_launched" })
    }
}
