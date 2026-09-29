import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1))) struct IrxJournalUploaderTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var statuses: [Int]
        private var tokens: [String] = []
        init(statuses: [Int]) { self.statuses = statuses }
        func record(_ request: URLRequest) -> Int {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        func recordToken(force: Bool) -> String {
            lock.lock(); defer { lock.unlock() }
            let token = force ? "fresh-token" : "cached-token"
            tokens.append(token)
            return token
        }
        var sent: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var issuedTokens: [String] { lock.lock(); defer { lock.unlock() }; return tokens }
    }

    private func event(
        component: String = "v2-control", event name: String = "refresh-failed",
        attributes: [String: String] = ["schema": "relay.request.v1"]
    ) -> IrxJournalEvent {
        IrxJournalEvent(
            wallTime: Date(timeIntervalSince1970: 1_789_000_000), monotonicMs: 12_345,
            component: component, event: name, attributes: attributes
        )
    }

    private func uploader(_ recorder: Recorder, flushInterval: TimeInterval = 600) -> IrxJournalUploader {
        IrxJournalUploader(
            endpoint: URL(string: "https://api.example.com/api/observability/transport")!,
            metadata: IrxJournalUploader.ClientMetadata(
                platform: "mac", clientChannel: "nightly", appVersion: "1.2",
                endpoint: "10533b43db35", deviceId: "device-1", buildTag: "default"
            ),
            token: { force in recorder.recordToken(force: force) },
            transport: { request in recorder.record(request) },
            flushInterval: flushInterval
        )
    }

    /// `offer` hops onto the actor asynchronously; poll until ready or timeout.
    private func drain(_ uploader: IrxJournalUploader, until ready: @Sendable () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !ready() {
            await uploader.flushNow()
            if ready() { return }
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for journal uploader readiness")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func exportsAllowlistedEventsWithMetadataAndBoundedAttributes() async throws {
        let recorder = Recorder(statuses: [200])
        let uploader = uploader(recorder)
        uploader.offer(event(attributes: ["schema": "relay.request.v1", "empty": ""]))
        // Denied component and denied periodic event never reach the wire.
        uploader.offer(event(component: "terminal-trace"))
        uploader.offer(event(component: "control-plane", event: "pong-sent"))
        try await drain(uploader) { !recorder.sent.isEmpty }
        let sent = recorder.sent
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.url?.path == "/api/observability/transport")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cached-token")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let batch = try #require(body?["batch"] as? [[String: Any]])
        #expect(batch.count == 1)
        #expect(batch.first?["component"] as? String == "v2-control")
        #expect(batch.first?["event"] as? String == "refresh-failed")
        #expect(batch.first?["platform"] as? String == "mac")
        #expect(batch.first?["clientChannel"] as? String == "nightly")
        #expect(batch.first?["endpoint"] as? String == "10533b43db35")
        #expect(batch.first?["buildTag"] as? String == "default")
        let attributes = batch.first?["attributes"] as? [String: String]
        #expect(attributes?["schema"] == "relay.request.v1")
        #expect(attributes?["empty"] == nil)
        #expect(await uploader.uploadedCount == 1)
    }

    @Test func unauthorizedUploadRetriesOnceWithAForcedToken() async throws {
        let recorder = Recorder(statuses: [401, 200])
        let uploader = uploader(recorder)
        uploader.offer(event())
        try await drain(uploader) { recorder.sent.count == 2 }
        #expect(recorder.sent.count == 2)
        #expect(recorder.issuedTokens == ["cached-token", "fresh-token"])
        #expect(recorder.sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
        #expect(await uploader.uploadedCount == 1)
    }

    @Test func stopPreventsAnInFlightUploadFromSending() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let returned = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            release.continuation.finish()
            returned.continuation.finish()
        }

        let recorder = Recorder(statuses: [200])
        let uploader = IrxJournalUploader(
            endpoint: URL(string: "https://api.example.com/api/observability/transport")!,
            metadata: IrxJournalUploader.ClientMetadata(
                platform: "mac", clientChannel: "nightly", appVersion: "1.2",
                endpoint: "10533b43db35", deviceId: "device-1", buildTag: "default"
            ),
            token: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                returned.continuation.yield(())
                return "token"
            },
            transport: { request in recorder.record(request) },
            flushInterval: 600
        )

        for _ in 0..<50 {
            uploader.offer(event())
        }
        var startedIterator = started.stream.makeAsyncIterator()
        #expect(await startedIterator.next() != nil)
        await uploader.stop()
        release.continuation.yield(())
        var returnedIterator = returned.stream.makeAsyncIterator()
        #expect(await returnedIterator.next() != nil)
        await uploader.flushNow()

        #expect(recorder.sent.isEmpty)
        #expect(await uploader.uploadedCount == 0)
    }

    @Test func transientFailureRetainsTheBatchAndRejectionDropsIt() async throws {
        let recorder = Recorder(statuses: [503, 200])
        let uploader = uploader(recorder)
        uploader.offer(event())
        try await drain(uploader) { recorder.sent.count == 1 }
        #expect(await uploader.uploadedCount == 0)
        await uploader.flushNow()
        #expect(await uploader.uploadedCount == 1)

        let rejecting = Recorder(statuses: [400])
        let dropper = self.uploader(rejecting)
        dropper.offer(event())
        try await drain(dropper) { rejecting.sent.count == 1 }
        #expect(await dropper.droppedCount == 1)
        await dropper.flushNow()
        #expect(rejecting.sent.count == 1)
    }

    @Test func journalTapDeliversRedactedEventsToTheUploader() async throws {
        let journal = IrxJournal(subsystem: "com.cmux.test", category: "uploader-tap-test")
        let recorder = Recorder(statuses: [200])
        let uploader = uploader(recorder)
        let tap = journal.addTap { [weak uploader] entry in uploader?.offer(entry) }
        journal.record("v2-control", "cooldown-set", ["schema": "relay.request.v1", "source": "rate_limited"])
        journal.record("terminal-trace", "host_received")
        try await drain(uploader) { !recorder.sent.isEmpty }
        journal.removeTap(tap)
        let request = try #require(recorder.sent.first)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let batch = try #require(body?["batch"] as? [[String: Any]])
        #expect(batch.count == 1)
        #expect(batch.first?["event"] as? String == "cooldown-set")
    }
}
