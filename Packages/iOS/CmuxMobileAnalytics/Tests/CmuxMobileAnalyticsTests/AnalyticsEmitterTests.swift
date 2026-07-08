import Foundation
import Testing

@testable import CmuxMobileAnalytics

private struct FixedConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

/// A consent gate whose value can be flipped between captures, so a test can
/// enqueue events while opted in and then withdraw consent before the flush.
private final class MutableConsent: AnalyticsConsentProviding, @unchecked Sendable {
    // Read on the emitter's `capture` (caller thread) and its drain (actor);
    // a lock keeps the flip race-free without an async hop on the capture path.
    private let lock = NSLock()
    private var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    var isTelemetryEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }
    func set(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
    }
}

@Suite struct AnalyticsEmitterTests {
    private func makeEmitter(
        uploader: RecordingAnalyticsUploader,
        consent: (any AnalyticsConsentProviding)? = nil,
        consentEnabled: Bool = true,
        anonymousID: String = "anon-1",
        flushBatchSize: Int = 50,
        maxPendingEvents: Int = 1000
    ) -> AnalyticsEmitter {
        AnalyticsEmitter(
            uploader: uploader,
            consent: consent ?? FixedConsent(isTelemetryEnabled: consentEnabled),
            anonymousID: anonymousID,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            flushBatchSize: flushBatchSize,
            maxPendingEvents: maxPendingEvents
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

    @Test func withdrawnConsentDropsEventsBufferedWhileEnabled() async {
        // Captured while opted in, but consent is revoked before the events
        // actually ship. The buffered backlog must be discarded, not uploaded —
        // the opt-out applies even to events queued while telemetry was enabled.
        let consent = MutableConsent(enabled: true)
        let uploader = RecordingAnalyticsUploader(result: .retry)
        let emitter = makeEmitter(uploader: uploader, consent: consent)
        emitter.capture("ios_terminal_input_submitted", ["byte_count": .int(7)])
        await emitter.flush() // .retry leaves the event buffered
        let batchesBeforeWithdrawal = await uploader.uploadedBatches.count
        // Withdraw consent, then let uploads succeed: the next flush must clear the
        // backlog instead of shipping it, so no further batch reaches the uploader.
        consent.set(false)
        await uploader.setResult(.accepted)
        await emitter.flush()
        #expect(await uploader.uploadedBatches.count == batchesBeforeWithdrawal)
        // Re-enabling does not resurrect the dropped events: nothing left to send.
        consent.set(true)
        await emitter.flush()
        #expect(await uploader.uploadedBatches.count == batchesBeforeWithdrawal)
    }

    @Test func optedOutIdentityUpdatesOnlyLocalState() async {
        let consent = MutableConsent(enabled: true)
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, consent: consent, anonymousID: "anon-9")

        emitter.identify(userId: "user-old", alias: nil, properties: [:])
        emitter.setSuperProperties(["is_authenticated": .bool(true)])
        await emitter.flush()
        #expect(await uploader.identifyCalls.count == 1)

        consent.set(false)
        emitter.setTelemetryConsentEnabled(false)
        emitter.identify(userId: nil, alias: nil, properties: [:])
        emitter.setSuperProperties(["is_authenticated": .bool(false)])
        consent.set(true)
        emitter.setTelemetryConsentEnabled(true)
        emitter.capture("ios_after_opt_in", [:])
        await emitter.flush()

        #expect(await uploader.identifyCalls.count == 1)
        let event = await uploader.uploadedEvents.last
        #expect(event?.distinctID == "anon-9")
        #expect(event?.anonymousID == nil)
        #expect(event?.properties["user_id"] == nil)
        #expect(event?.properties["is_authenticated"] == .bool(false))
    }

    @Test func consentWithdrawalClearsBufferedEventsEvenIfReenabledBeforeFlush() async {
        let consent = MutableConsent(enabled: true)
        let uploader = RecordingAnalyticsUploader()
        let emitter = makeEmitter(uploader: uploader, consent: consent)

        emitter.capture("ios_before_opt_out", [:])
        consent.set(false)
        emitter.setTelemetryConsentEnabled(false)
        consent.set(true)
        emitter.setTelemetryConsentEnabled(true)
        emitter.capture("ios_after_opt_in", [:])
        await emitter.flush()

        let names = await uploader.uploadedEvents.map(\.name)
        #expect(names == ["ios_after_opt_in"])
    }

    @Test func sustainedRetryBoundsBacklogByDroppingOldest() async {
        // A stuck uploader (.retry forever) must not let the pending buffer grow
        // without limit. With a cap of 4, only the 4 newest of 20 events survive.
        let uploader = RecordingAnalyticsUploader(result: .retry)
        let emitter = makeEmitter(
            uploader: uploader,
            flushBatchSize: 2,
            maxPendingEvents: 4
        )
        for index in 0..<20 {
            emitter.capture("ios_event", ["seq": .int(index)])
        }
        // Let the outage clear; the bounded backlog ships on the next flush. The
        // final accepted batch is the only one whose events were actually retired,
        // so it holds exactly the survivors (earlier batches were retry attempts).
        await emitter.flush()
        await uploader.setResult(.accepted)
        await emitter.flush()
        let finalBatch = await uploader.uploadedBatches.last ?? []
        let survivors = finalBatch.compactMap { event -> Int? in
            if case let .int(seq)? = event.properties["seq"] { return seq }
            return nil
        }
        #expect(survivors.count <= 4)
        // Drop-oldest: the surviving seqs are the highest (newest) ones.
        #expect(survivors.allSatisfy { $0 >= 16 })
    }
}
