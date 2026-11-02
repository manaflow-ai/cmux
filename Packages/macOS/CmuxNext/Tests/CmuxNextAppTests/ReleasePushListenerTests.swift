@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The release push (Leo 2026-10-26: "if the nightly is post, I just want it. Just give it to me.
/// Don't wait... there should be some sort of hook, so you can just do the thing."): one socket to
/// the Worker's feed, one check per newer build, and nothing at all for a feed it does not serve
/// or with the opt-in off.
@MainActor @Suite(.serialized) struct ReleasePushListenerTests {
    static let nightlyFeed = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
    static let tipFeed = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"
    /// The old feed cmux NIGHTLY (com.cmuxterm.app.nightly) reads.
    static let legacyFeed = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"

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
        let before = h.sockets.count
        h.listener.refresh(feedURL: feed)
        try #require(await eventually { h.sockets.count == before + 1 }, "the listener never connected")
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
        defer { h.listener.stop() }
        let socket = try await connected(h)
        #expect(h.urls == [URL(string: "wss://presence.cmux.dev/releases/v1/socket?feed=nightly-next")!])
        socket.deliver(Self.frame(200))
        #expect(await eventually { h.checks == [200] }, "build 200 is newer than build 100 but nothing checked")
    }

    @Test func anEqualOrLowerBuildStartsNone() async throws {
        let h = Harness()
        defer { h.listener.stop() }
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
        defer { h.listener.stop() }
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

    @Test func turningThePushOffClosesTheSocketAndStopsReconnecting() async throws {
        let h = Harness()
        defer { h.listener.stop() }
        let socket = try await connected(h)
        h.listener.refresh(feedURL: nil)
        #expect(socket.closed, "the socket stayed open with the push off")
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

    @Test func aBuildActedOnInOneFeedDoesNotHideTheOther() async throws {
        let h = Harness()
        defer { h.listener.stop() }
        let nightly = try await connected(h)
        try await settle(h, nightly, marker: 300)
        let tip = try await connected(h, feed: Self.tipFeed)
        #expect(nightly.closed, "the nightly socket stayed open after the feed changed")
        tip.deliver(Self.frame(200, feed: "tip"))
        #expect(await eventually { h.checks == [300, 200] }, "the nightly build acted on hid the tip feed's newer build")
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

    /// Leo 2026-10-27: "but why shoudl there be a delay if we can just listen". cmux NIGHTLY reads
    /// the old feed: it listens on that feed's own id, and only that feed's frames start a check.
    @Test func theNightlyAppListensOnTheOldFeedAndOnlyActsOnItsOwnFrames() async throws {
        let legacy = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly", shortVersion: "0.1.0", build: "100",
                                         minimumSystemVersion: nil, infoFeedURL: Self.legacyFeed, hasPublicKey: true)
        #expect(legacy.track == .nightlyNext)
        #expect(ReleasePushListener.feedID(forFeedURL: legacy.feed(architecture: .arm64).url) == "nightly-next-legacy")
        // The old feed's Intel appcast is not one the Worker serves.
        #expect(ReleasePushListener.feedID(forFeedURL: "https://files-next.cmux.com/nightly-next/appcast-x86_64.xml") == nil)

        let h = Harness()
        defer { h.listener.stop() }
        let socket = try await connected(h, feed: Self.legacyFeed)
        #expect(h.urls == [URL(string: "wss://presence.cmux.dev/releases/v1/socket?feed=nightly-next-legacy")!])
        // Frames for cmux NEXT's own feeds are not this app's feed: nothing checks.
        socket.deliver(Self.frame(500, feed: "nightly-next"))
        socket.deliver(Self.frame(600, feed: "tip"))
        socket.deliver(Self.frame(200, feed: "nightly-next-legacy"))
        #expect(await eventually { h.checks == [200] }, "the old feed's build did not check, or another feed's did")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.checks == [200], "a frame for another feed started a check")
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
        defer { h.listener.stop() }
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
        defer { h.listener.stop() }
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
        // A release frame is not an answer to the ping.
        try await settle(h, socket, marker: 201)
        // No pong within the next minute: the socket is closed and replaced.
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
        private let pubDate: String
        private var newest = 100
        private var count = 0
        init(pubDate: String) { self.pubDate = pubDate }
        var fetches: Int { lock.withLock { count } }
        func publish(_ build: Int) { lock.withLock { newest = build } }
        func fetch(_ url: URL) async throws -> Data {
            let build = lock.withLock { count += 1; return newest }
            return Data("""
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
            <item><title>nightly</title><sparkle:version>\(build)</sparkle:version><pubDate>\(pubDate)</pubDate></item>
            </channel></rss>
            """.utf8)
        }
    }

    struct Service {
        let updater: UpdaterService
        let clock: ManualClock
        /// The push's quick-read deadline alone sleeps on this one.
        let retryClock: ManualClock
        let feed: MovingFeed
        let fake: Fakes
        var sockets: [FakeSocket] { fake.sockets }
        func configure(checks automatic: Bool = true, downloads: Bool) {
            updater.configure(checkAutomatically: automatic, checkInterval: 3600, downloadAutomatically: downloads, ring: "nightly")
        }
    }

    /// What the fakes saw: the sockets opened, the checks started (by the fast check or the staged
    /// swap), the staged build, and the staged installers cancelled.
    @MainActor final class Fakes {
        var sockets: [FakeSocket] = []
        var checks = 0
        var staged: String?
        var cancels = 0
    }

    /// A started NIGHTLY on build 100 whose feed answers with build 100; the opt-in as given.
    func service(downloads: Bool) throws -> Service {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.release-push", shortVersion: "0.1.0", build: "100",
                                           minimumSystemVersion: nil, infoFeedURL: Self.nightlyFeed, hasPublicKey: true)
        try #require(identity.feed().url == Self.nightlyFeed, "this Mac does not read the arm64 feed")
        let clock = ManualClock()
        let feed = MovingFeed(pubDate: UpdateStagedYieldsToNewerTests.pubDate(minutesAgo: 1))
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, prober: UpdateProber(fetcher: feed, architecture: .arm64),
                                     defaults: UserDefaults(suiteName: "ReleasePushListenerTests.\(UUID().uuidString)")!,
                                     enableSparkle: false, recordsUpdates: false, now: { UpdateStagedYieldsToNewerTests.now }, clock: clock)
        updater.announcementsFetch = false
        updater.notesLoader = { _ in nil }
        let retryClock = ManualClock()
        updater.releasePushRetry = DemandTimer(owner: "ReleasePushListenerTests.retry", clock: retryClock)
        let fake = Fakes()
        updater.releasePush.connect = { _ in
            let socket = FakeSocket()
            fake.sockets.append(socket)
            return socket
        }
        updater.tipCheck.startCheck = { fake.checks += 1 }
        updater.stagedBuild = { fake.staged }
        updater.cancelStaged = { fake.cancels += 1; return true }
        updater.stagedRefresh.replaceable = { true }
        updater.stagedRefresh.startCheck = { fake.checks += 1 }
        let s = Service(updater: updater, clock: clock, retryClock: retryClock, feed: feed, fake: fake)
        s.configure(downloads: downloads)
        updater.start()
        return s
    }

    /// Advances to the push's next read once its deadline sleeps (the only sleeper on its clock).
    func nextPushRead(_ s: Service, until reached: () -> Bool) async throws {
        try #require(await eventually { s.updater.releasePushRetry.isScheduled }, "no quick read was armed")
        try await s.retryClock.waitForSleeper()
        s.retryClock.advance(by: UpdaterService.releasePushRetryDelay)
        try #require(await eventually(reached), "the push's next read did not happen")
    }

    @Test func theUpdaterReadsTheFeedAtOnceWhileAutomaticChecksAreOn() async throws {
        let s = try service(downloads: true)
        defer { s.updater.stopReleasePush() }
        try #require(await eventually { s.sockets.count == 1 }, "the push did not start")
        // The frame reads the feed at once; its edge still answers with build 100.
        s.sockets[0].deliver(Self.frame(200))
        try #require(await eventually { s.feed.fetches == 1 && s.updater.tipCheck.task == nil }, "the pushed build read no feed")
        #expect(s.fake.checks == 0)
        // The next read is a short wait away, not the 15-minute interval, and finds build 200.
        s.feed.publish(200)
        try await nextPushRead(s) { s.fake.checks == 1 }
        // Asked for: the next deadline finds the build reached and ends the push's reads.
        try await nextPushRead(s) { s.updater.releasePushTarget == nil }
        #expect(s.fake.checks == 1, "the pushed build was checked for twice")

        // Automatic checks off stop it, with or without the opt-in, and keep it quiet.
        s.configure(checks: false, downloads: true)
        #expect(s.sockets[0].closed && s.updater.releasePush.task == nil, "the push kept running with automatic checks off")
        s.configure(checks: false, downloads: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.sockets.count == 1, "the push connected with automatic checks off")
        s.configure(downloads: true)
        try #require(await eventually { s.sockets.count == 2 })
        // The opt-in off leaves it running (the pushed build's check then asks first).
        s.configure(downloads: false)
        #expect(!s.sockets[1].closed && s.updater.releasePush.task != nil, "the opt-in off closed the push")
        // The app quits: the socket closes.
        s.updater.stopReleasePush()
        #expect(s.sockets[1].closed && s.updater.releasePush.task == nil && !s.updater.releasePushRetry.isScheduled)
    }

    /// Without the automatic-install opt-in (the default on every channel, Leo 2026-10-27: "ask
    /// before the download + install step"), a release push still checks at once, and the found
    /// build asks: the update-found step (the titlebar's Update Available), nothing downloaded,
    /// nothing staged, no relaunch.
    @Test func withoutTheOptInAPushChecksAndTheFoundUpdateAsks() async throws {
        let s = try service(downloads: false)
        defer { s.updater.stopReleasePush() }
        try #require(await eventually { s.sockets.count == 1 }, "the push waited for the automatic-install opt-in")
        var downloads = 0
        s.updater.acceptAvailable = { downloads += 1 }
        s.feed.publish(200)
        s.sockets[0].deliver(Self.frame(200))
        try #require(await eventually { s.fake.checks == 1 }, "the pushed build started no check")
        // The check runs and finds build 200: it asks.
        s.updater.debugIndicatorPhase = .checking
        #expect(s.updater.card == nil, "the pushed build's check showed its progress")
        s.updater.debugIndicatorPhase = .available(version: "2.0.0")
        #expect(s.updater.availableButton == UpdateAvailableButton(version: "2.0.0"), "the pushed build did not ask")
        #expect(downloads == 0 && s.updater.readyCard == nil, "the pushed build downloaded without an answer")
        // Update answers the found step: it downloads, and nothing installs yet.
        s.updater.downloadClicked()
        #expect(downloads == 1, "Update did not download the found build")
    }

    @Test func aBuildPushedWhileOneDownloadsReplacesItOnceStaged() async throws {
        let s = try service(downloads: true)
        defer { s.updater.stopReleasePush() }
        try #require(await eventually { s.sockets.count == 1 })
        s.updater.debugIndicatorPhase = .checking
        s.sockets[0].deliver(Self.frame(200))
        try #require(await eventually { s.updater.releasePushTarget?.build == "200" })
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.feed.fetches == 0, "the feed was read while a check ran")
        // Build 150 is staged; the feed's edge still answers with it, then with build 200.
        s.feed.publish(150)
        s.fake.staged = "150"
        s.updater.debugIndicatorPhase = .ready(version: "1.5.0")
        try #require(await eventually { s.feed.fetches == 1 && s.updater.stagedRefresh.task == nil }, "the staged build was not probed")
        #expect(s.fake.cancels == 0 && s.fake.checks == 0)
        s.feed.publish(200)
        try await nextPushRead(s) { s.fake.cancels == 1 && s.fake.checks == 1 }
    }
}
