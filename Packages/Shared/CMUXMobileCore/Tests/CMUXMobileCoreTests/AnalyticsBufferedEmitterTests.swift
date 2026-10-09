import Foundation
import Testing

@testable import CMUXMobileCore

@Suite("Buffered analytics")
struct AnalyticsBufferedEmitterTests {
    @Test func offlineDropsQueuedEventsWithoutCallingTransport() async {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { false },
            batchingInterval: 60
        )

        analytics.capture("ios_app_launched")
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        #expect(bodies.isEmpty)
        analytics.cancel()
    }

    @Test func splitsBatchesAtConfiguredEventLimit() async throws {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            maxBatchEvents: 2,
            batchingInterval: 60
        )

        for _ in 0..<5 {
            analytics.capture("ios_app_launched")
        }
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        #expect(bodies.count == 3)
        let counts = try bodies.map { body in
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return (object["batch"] as? [[String: Any]])?.count
        }
        #expect(counts == [2, 2, 1])
        analytics.cancel()
    }

    @Test func flushCannotBeDroppedWhenTheEventQueueIsFull() async {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            queueCapacity: 1,
            batchingInterval: 60
        )

        for _ in 0..<10 {
            analytics.capture("ios_app_launched")
        }
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        #expect(bodies.count == 1)
        analytics.cancel()
    }

    @Test func concurrentFlushesCompleteFromOneDrain() async {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            batchingInterval: 60
        )
        analytics.capture("ios_app_launched")

        async let first: Void = analytics.flush()
        async let second: Void = analytics.flush()
        _ = await (first, second)

        let bodies = await transport.uploadedBodies
        #expect(bodies.count == 1)
        analytics.cancel()
    }

    @Test func cancellingOneFlushDoesNotCancelTheEmitter() async {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            batchingInterval: 60
        )

        let flushTask = Task { await analytics.flush() }
        flushTask.cancel()
        await flushTask.value

        analytics.capture("ios_app_launched")
        await analytics.flush()
        let bodies = await transport.uploadedBodies
        #expect(bodies.count == 1)
        analytics.cancel()
    }

    @Test func splitsBatchesAtEncodedBodyLimit() async throws {
        let transport = RecordingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            maxRequestBytes: 200,
            batchingInterval: 60
        )

        for _ in 0..<3 {
            analytics.capture(
                "ios_app_launched",
                ["value": .string(String(repeating: "x", count: 40))]
            )
        }
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        #expect(bodies.count == 3)
        for body in bodies {
            #expect(body.count <= 200)
        }
        analytics.cancel()
    }

    @Test func dropsInvalidEventsWithoutRetrying() async {
        let transport = RecordingTransport(outcomes: [.retry, .accepted])
        let sleep = SleepRecorder()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            batchingInterval: 60,
            sleep: { delay in
                guard !Task.isCancelled else { return }
                await sleep.record(delay)
            }
        )

        analytics.capture("ios_private_payload")
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        let delays = await sleep.delays
        #expect(bodies.isEmpty)
        #expect(delays.isEmpty)
        analytics.cancel()
    }

    @Test func retriesTransientFailureWithInjectedBackoff() async {
        let transport = RecordingTransport(outcomes: [.retry, .retry, .accepted])
        let sleep = SleepRecorder()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            batchingInterval: 60,
            retryBaseDelay: 0.25,
            retryMaxDelay: 10,
            sleep: { delay in
                guard !Task.isCancelled else { return }
                await sleep.record(delay)
            }
        )

        analytics.capture("ios_app_launched")
        await analytics.flush()

        let bodies = await transport.uploadedBodies
        let delays = await sleep.delays
        #expect(bodies.count == 3)
        #expect(delays == [0.25, 0.5])
        analytics.cancel()
    }

    @Test func cancellationStopsAnInFlightUpload() async {
        let transport = BlockingTransport()
        let analytics = BufferedAnalytics(
            transport: transport,
            isReachable: { true },
            batchingInterval: 0
        )
        analytics.capture("ios_app_launched")
        await transport.waitUntilStarted()

        analytics.cancel()
        await transport.waitUntilCancelled()
        let wasCancelled = await transport.wasCancelled
        #expect(wasCancelled)
    }
}

private actor RecordingTransport: AnalyticsUploadTransport {
    private var outcomes: [AnalyticsUploadResult]
    private(set) var uploadedBodies: [Data] = []

    init(outcomes: [AnalyticsUploadResult] = [.accepted]) {
        self.outcomes = outcomes
    }

    func upload(_ body: Data) async throws -> AnalyticsUploadResult {
        uploadedBodies.append(body)
        if outcomes.isEmpty {
            return .accepted
        }
        return outcomes.removeFirst()
    }
}

private actor SleepRecorder {
    private(set) var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }
}

private actor BlockingTransport: AnalyticsUploadTransport {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancelledContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var wasCancelled = false

    func upload(_ body: Data) async throws -> AnalyticsUploadResult {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .accepted
        } catch {
            wasCancelled = true
            cancelledContinuation?.resume()
            cancelledContinuation = nil
            return .retry
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilCancelled() async {
        if wasCancelled { return }
        await withCheckedContinuation { continuation in
            cancelledContinuation = continuation
        }
    }
}
