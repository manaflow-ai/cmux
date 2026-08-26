import Foundation
import Testing
@testable import CMUXMobileCore

/// Captures the subscriber's injected sleeps and stops the loop by throwing
/// cancellation once enough delays are recorded. Keeping this actor at file
/// scope avoids an Xcode 16 compiler crash while deriving the enclosing suite.
private actor ConnectivityInvalidationSubscriberSleepRecorder {
    private let stopAfter: Int
    private var delays: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(stopAfter: Int) {
        self.stopAfter = stopAfter
    }

    func record(_ delay: TimeInterval) throws {
        guard delays.count < stopAfter else { throw CancellationError() }
        delays.append(delay)
        if delays.count == stopAfter {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            throw CancellationError()
        }
    }

    func recorded() -> [TimeInterval] { delays }

    func waitUntilStopped() async {
        guard delays.count < stopAfter else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Connectivity invalidation subscriber")
struct CmxConnectivityInvalidationSubscriberTests {
    @Test("parses the exact bounded revision-only frame")
    func parsesFrame() throws {
        let data = Data(
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":42,"at":1800000000000}"#
                .utf8
        )

        #expect(try CmxConnectivityInvalidation.parse(data) == .init(
            revision: 42,
            acceptedAtMilliseconds: 1_800_000_000_000
        ))
    }

    @Test("rejects route material, wrong protocol, booleans, and oversized frames")
    func rejectsInvalidFrames() {
        let invalidFrames = [
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":1,"at":2,"routes":[]}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":2,"revision":1,"at":2}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":0,"at":2}"#,
            #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":true,"at":2}"#,
            {
                let padding = String(
                    repeating: "p",
                    count: CmxConnectivityInvalidation.maximumFrameBytes
                )
                return #"{"type":"connectivity.invalidate","protocolVersion":1,"revision":1,"at":2,"pad":"\#(padding)"}"#
            }(),
        ]

        for text in invalidFrames {
            #expect(throws: CmxConnectivityInvalidationError.invalidFrame) {
                try CmxConnectivityInvalidation.parse(Data(text.utf8))
            }
        }
    }

    @Test("normalizes malformed JSON to the bounded invalid-frame error")
    func normalizesMalformedJSON() {
        #expect(throws: CmxConnectivityInvalidationError.invalidFrame) {
            try CmxConnectivityInvalidation.parse(Data(#"{"revision":"#.utf8))
        }
    }

    @Test("failed subscribes follow the shared seeded reconnect ladder")
    func failedSubscribesFollowSharedBackoffLadder() async {
        let seed: UInt64 = 0x5EED
        let drawCount = 8
        let recorder = ConnectivityInvalidationSubscriberSleepRecorder(stopAfter: drawCount)
        let subscriber = CmxConnectivityInvalidationSubscriber(
            serviceBaseURL: URL(string: "https://presence.example.test")!,
            // A missing token classifies the attempt as failed before any
            // network use, so the loop exercises only the retry ladder.
            accessToken: { nil },
            backoff: CmxReconnectBackoff(seed: seed),
            sleep: { try await recorder.record($0) },
            handler: { _ in }
        )

        await subscriber.start()
        await recorder.waitUntilStopped()
        await subscriber.stop()

        // The private exponential schedule is gone: every delay matches a
        // same-seed twin of the one shared ladder and respects its 30 s
        // foreground cap, instead of the old unjittered 1,2,4...60 s ramp.
        let twin = CmxReconnectBackoff(seed: seed)
        let expected = (0 ..< drawCount).map { _ in twin.nextDelay() }
        let recorded = await recorder.recorded()
        #expect(recorded == expected)
        #expect(recorded.allSatisfy {
            $0 <= CmxReconnectBackoffConfiguration.foreground.cap
        })
    }

    @Test("resolves the dedicated account WebSocket route")
    func resolvesSubscribeURL() throws {
        let base = try #require(URL(string: "https://presence.example.test/dev/"))
        #expect(
            CmxConnectivityInvalidationSubscriber.subscribeURL(serviceBaseURL: base)?
                .absoluteString
                == "wss://presence.example.test/dev/v1/connectivity/subscribe"
        )
        #expect(
            CmxConnectivityInvalidationSubscriber.subscribeURL(
                serviceBaseURL: try #require(URL(string: "ftp://presence.example.test"))
            ) == nil
        )
    }
}
