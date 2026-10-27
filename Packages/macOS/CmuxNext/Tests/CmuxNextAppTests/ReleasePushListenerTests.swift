@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

/// The release push (Leo 2026-10-26: "if the nightly is post, I just want it. Just give it to me.
/// Don't wait... there should be some sort of hook, so you can just do the thing."): one socket to
/// the Worker's feed, one check per newer build, and nothing at all for a feed it does not serve
/// or with the opt-in off.
@MainActor @Suite(.serialized) struct ReleasePushListenerTests {
    static let nightlyFeed = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    static let tipFeed = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"

    /// A socket the test sends frames on; ``cancel()`` (the listener's close, or the server's) ends it.
    nonisolated final class FakeSocket: ReleasePushSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [String?] = []
        private var waiter: CheckedContinuation<String?, any Error>?
        private var isClosed = false
        private var sentTexts: [String] = []

        var closed: Bool { lock.withLock { isClosed } }
        var sent: [String] { lock.withLock { sentTexts } }

        /// The server sends `text`.
        func deliver(_ text: String?) {
            let waiter: CheckedContinuation<String?, any Error>? = lock.withLock {
                guard !isClosed else { return nil }
                if let waiter = self.waiter { self.waiter = nil; return waiter }
                queued.append(text)
                return nil
            }
            waiter?.resume(returning: text)
        }

        func receive() async throws -> String? {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
                let outcome: Result<String?, any Error>? = lock.withLock {
                    if isClosed { return .failure(URLError(.cancelled)) }
                    if !queued.isEmpty { return .success(queued.removeFirst()) }
                    waiter = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        }

        func send(_ text: String) async throws {
            try lock.withLock {
                if isClosed { throw URLError(.cancelled) }
                sentTexts.append(text)
            }
        }

        func cancel() {
            let waiter: CheckedContinuation<String?, any Error>? = lock.withLock {
                isClosed = true
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(throwing: URLError(.cancelled))
        }
    }

    @MainActor final class Harness {
        let clock = ManualClock()
        var sockets: [FakeSocket] = []
        var urls: [URL] = []
        /// The builds the listener asked the updater to check for.
        var checks: [Int64] = []
        var listener: ReleasePushListener!

        init(runningBuild: String = "100") {
            listener = ReleasePushListener(runningBuild: runningBuild, clock: clock, log: { _ in }, jitter: { 1 }) { [unowned self] url in
                let socket = FakeSocket()
                self.sockets.append(socket)
                self.urls.append(url)
                return socket
            }
            listener.onNewerBuild = { [unowned self] build in self.checks.append(build) }
        }

        var socket: FakeSocket? { sockets.last }
    }

    static func frame(_ build: Int64, feed: String = "nightly-next") -> String {
        #"{"type":"release","feed":"\#(feed)","build":\#(build),"version":"1.0.0-nightly.\#(build)","at":"2026-10-26T23:10:00Z"}"#
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    /// Connects and waits until the listener reads its first frame.
    func connected(_ h: Harness, feed: String = nightlyFeed) async throws -> FakeSocket {
        h.listener.refresh(feedURL: feed)
        try #require(await eventually { h.socket != nil }, "the listener never connected")
        return try #require(h.socket)
    }

    /// The socket closed and the reconnect's backoff sleep is the only sleeper on the clock.
    func reconnectWaiting(_ h: Harness) async throws {
        try #require(await eventually { h.listener.socket == nil && h.clock.sleeperCount == 1 }, "no reconnect wait")
    }

    /// Delivers `text` and then a build known to act, so the test knows `text` was read.
    func settle(_ h: Harness, _ socket: FakeSocket, marker: Int64) async throws {
        let before = h.checks.count
        socket.deliver(Self.frame(marker))
        try #require(await eventually { h.checks.count > before }, "the marker frame was not read")
    }

    @Test func aHigherBuildStartsOneCheck() async throws {
        let h = Harness()
        let socket = try await connected(h)
        #expect(h.urls == [URL(string: "wss://presence.cmux.dev/releases/v1/socket?feed=nightly-next")!])
        socket.deliver(Self.frame(200))
        #expect(await eventually { h.checks == [200] }, "build 200 is newer than build 100 but nothing checked")
    }

    @Test func anEqualOrLowerBuildStartsNone() async throws {
        let h = Harness()
        let socket = try await connected(h)
        socket.deliver(Self.frame(100))
        socket.deliver(Self.frame(42))
        socket.deliver("pong")
        socket.deliver(nil)
        socket.deliver(Self.frame(500, feed: "tip"))
        socket.deliver(#"{"type":"other","feed":"nightly-next","build":900}"#)
        socket.deliver("not json")
        try await settle(h, socket, marker: 101)
        #expect(h.checks == [101], "a build at or below the running one, another feed or another frame started a check")
    }

    @Test func aDuplicateFrameStartsNone() async throws {
        let h = Harness()
        let socket = try await connected(h)
        socket.deliver(Self.frame(200))
        socket.deliver(Self.frame(200))
        socket.deliver(Self.frame(150))
        try await settle(h, socket, marker: 300)
        #expect(h.checks == [200, 300], "a build already acted on started a second check")
        // A reconnect's first frame repeats the newest build: still nothing.
        socket.cancel()
        try await reconnectWaiting(h)
        h.clock.advance(by: .seconds(ReleasePushListener.maximumBackoff))
        try #require(await eventually { h.sockets.count == 2 }, "the listener did not reconnect")
        let again = try #require(h.socket)
        again.deliver(Self.frame(300))
        try await settle(h, again, marker: 301)
        #expect(h.checks == [200, 300, 301])
    }

    @Test func turningTheOptInOffClosesTheSocketAndStopsReconnecting() async throws {
        let h = Harness()
        let socket = try await connected(h)
        h.listener.refresh(feedURL: nil)
        #expect(socket.closed, "the socket stayed open with the opt-in off")
        #expect(h.listener.task == nil && h.listener.socket == nil && h.listener.feed == nil)
        h.clock.advance(by: .seconds(ReleasePushListener.maximumBackoff * 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sockets.count == 1, "the listener reconnected after it was turned off")
        #expect(h.clock.sleeperCount == 0, "a reconnect or ping sleep outlived the stop")
        // On again: one new connection.
        _ = try await connected(h)
        #expect(h.sockets.count == 2)
        h.listener.stop()
        #expect(h.socket?.closed == true)
    }

    @Test func anUnknownFeedNeverConnects() async throws {
        for feed in ["https://files.cmux.com/appcast.xml", "https://files-next.cmux.com/nightly-next/next/appcast-x86_64.xml",
                     "https://example.com/nightly-next/next/appcast-arm64.xml", nil] {
            let h = Harness()
            h.listener.refresh(feedURL: feed)
            #expect(h.listener.task == nil && h.listener.feed == nil, "feed \(feed ?? "nil") started the listener")
            try await Task.sleep(for: .milliseconds(20))
            #expect(h.sockets.isEmpty, "feed \(feed ?? "nil") connected")
        }
        // A running build that is no integer never compares: nothing connects either.
        let h = Harness(runningBuild: "1.2.3")
        h.listener.refresh(feedURL: Self.nightlyFeed)
        #expect(h.listener.task == nil && h.sockets.isEmpty)
        // Both allowlisted feeds connect to their own id.
        #expect(ReleasePushListener.feedID(forFeedURL: Self.tipFeed) == "tip")
        #expect(ReleasePushListener.feedID(forFeedURL: Self.nightlyFeed) == "nightly-next")
    }

    @Test func theAppsOwnFeedsResolveToAllowlistedURLs() {
        let nightly = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next", shortVersion: "0.1.0", build: "100",
                                          minimumSystemVersion: nil, infoFeedURL: Self.nightlyFeed, hasPublicKey: true)
        let tip = UpdateBuildIdentity(bundleIdentifier: UpdateBuildIdentity.tipBundleIdentifier, shortVersion: "0.1.0", build: "100",
                                      minimumSystemVersion: nil, infoFeedURL: Self.tipFeed, hasPublicKey: true)
        #expect(ReleasePushListener.feedID(forFeedURL: nightly.feed(architecture: .arm64).url) == "nightly-next")
        #expect(ReleasePushListener.feedID(forFeedURL: tip.feed(architecture: .arm64).url) == "tip")
    }

    @Test func backoffIsBounded() {
        var previous: Duration = .zero
        for failures in 0...200 {
            for jitter in [0, 0.25, 1, -3, 7, .nan, .infinity] {
                let delay = ReleasePushListener.backoff(failures: failures, jitter: jitter)
                #expect(delay >= .seconds(1) && delay <= .seconds(300), "failures \(failures) jitter \(jitter): \(delay)")
            }
            let top = ReleasePushListener.backoff(failures: failures, jitter: 1)
            #expect(top >= previous, "the backoff shrank at \(failures) failures")
            previous = top
        }
        #expect(ReleasePushListener.backoff(failures: 1, jitter: 1) == .seconds(1))
        #expect(ReleasePushListener.backoff(failures: 4, jitter: 1) == .seconds(8))
        #expect(ReleasePushListener.backoff(failures: 4, jitter: 0) == .seconds(4))
        #expect(ReleasePushListener.backoff(failures: 1_000, jitter: 1) == .seconds(300))
        #expect(ReleasePushListener.backoff(failures: .max, jitter: 1) == .seconds(300))
    }

    @Test func aDeadSocketReconnectsAfterTheBackoffAndResetsOnceHeard() async throws {
        let h = Harness()
        let first = try await connected(h)
        first.cancel()
        try await reconnectWaiting(h)
        h.clock.advance(by: .milliseconds(999))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.sockets.count == 1, "reconnected before the 1 s backoff")
        h.clock.advance(by: .milliseconds(1))
        try #require(await eventually { h.sockets.count == 2 })
        // That one hears nothing: the next wait doubles.
        h.socket?.cancel()
        try await reconnectWaiting(h)
        #expect(h.listener.failures == 2)
        h.clock.advance(by: .seconds(2))
        try #require(await eventually { h.sockets.count == 3 })
        // A connection that heard a frame resets the backoff.
        let third = try #require(h.socket)
        try await settle(h, third, marker: 200)
        third.cancel()
        try await reconnectWaiting(h)
        #expect(h.listener.failures == 1)
    }

    @Test func itPingsEveryMinuteAndReconnectsWhenAPingGoesUnanswered() async throws {
        let h = Harness()
        let socket = try await connected(h)
        try await h.clock.waitForSleeper()
        h.clock.advance(by: ReleasePushListener.pingInterval)
        try #require(await eventually { socket.sent == ["ping"] }, "no ping after a minute")
        socket.deliver("pong")
        try await settle(h, socket, marker: 200)
        try await h.clock.waitForSleeper()
        h.clock.advance(by: ReleasePushListener.pingInterval)
        try #require(await eventually { socket.sent == ["ping", "ping"] }, "no second ping")
        #expect(!socket.closed, "an answered ping closed the socket")
        // No answer within the next minute: the socket is closed and replaced.
        try await h.clock.waitForSleeper()
        h.clock.advance(by: ReleasePushListener.pingInterval)
        try #require(await eventually { socket.closed }, "an unanswered ping left the socket open")
        try await reconnectWaiting(h)
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { h.sockets.count == 2 }, "the dead socket was not replaced")
    }

    /// A feed whose newest build the test moves (the edge answering with the build before the pushed one).
    nonisolated final class MovingFeed: AppcastFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var newest = 100
        private var count = 0
        var fetches: Int { lock.withLock { count } }
        func publish(_ build: Int) { lock.withLock { newest = build } }
        func fetch(_ url: URL) async throws -> Data {
            let build = lock.withLock { count += 1; return newest }
            return Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
            <item><title>nightly</title><sparkle:version>\(build)</sparkle:version><pubDate>\(UpdateStagedYieldsToNewerTests.pubDate(minutesAgo: 1))</pubDate></item>
            </channel></rss>
            """.utf8)
        }
    }

    @Test func theUpdaterReadsTheFeedAtOnceAndOnlyWithTheOptInOn() async throws {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.release-push", shortVersion: "0.1.0", build: "100",
                                           minimumSystemVersion: nil, infoFeedURL: Self.nightlyFeed, hasPublicKey: true)
        try #require(identity.feed().url == Self.nightlyFeed, "this Mac does not read the arm64 feed")
        let clock = ManualClock()
        let feed = MovingFeed()
        let updater = UpdaterService(identity: identity, prober: UpdateProber(fetcher: feed, architecture: .arm64),
                                     defaults: UserDefaults(suiteName: "ReleasePushListenerTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false, now: { UpdateStagedYieldsToNewerTests.now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        var sockets: [FakeSocket] = []
        var checks = 0
        updater.releasePush.connect = { _ in
            let socket = FakeSocket()
            sockets.append(socket)
            return socket
        }
        updater.tipCheck.startCheck = { checks += 1 }
        updater.tipCheck.downloadsInBackground = { true }
        func configure(checks automatic: Bool = true, downloads: Bool) {
            updater.configure(checkAutomatically: automatic, checkInterval: 3600, downloadAutomatically: downloads, ring: "nightly")
        }
        configure(downloads: false)
        updater.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(sockets.isEmpty && updater.releasePush.task == nil, "the push ran with automatic download and install off")

        configure(downloads: true)
        try #require(await eventually { sockets.count == 1 }, "the push did not start with the opt-in on")
        // The frame reads the feed at once; its edge still answers with build 100.
        sockets[0].deliver(Self.frame(200))
        try #require(await eventually { feed.fetches == 1 && updater.tipCheck.task == nil }, "the pushed build read no feed")
        #expect(checks == 0)
        // The next read is a short wait away, not the 15-minute interval, and finds build 200.
        feed.publish(200)
        // Asleep on the clock: the socket's ping and the retry's deadline.
        try #require(await eventually { clock.sleeperCount >= 2 }, "no quick read was armed")
        clock.advance(by: .seconds(TipUpdateCheck.pushRetryDelay))
        #expect(await eventually { checks == 1 }, "the pushed build was never checked for")
        #expect(updater.tipCheck.pushedBuild == nil)

        // Automatic checks off stop it, and so does the opt-in off.
        configure(checks: false, downloads: true)
        #expect(sockets[0].closed && updater.releasePush.task == nil, "the push kept running with automatic checks off")
        configure(downloads: true)
        try #require(await eventually { sockets.count == 2 })
        configure(downloads: false)
        #expect(sockets[1].closed && updater.releasePush.task == nil, "the socket stayed open with the opt-in off")
        // The app quits: the socket closes.
        configure(downloads: true)
        try #require(await eventually { sockets.count == 3 })
        updater.stopReleasePush()
        #expect(sockets[2].closed && updater.releasePush.task == nil)
    }
}
