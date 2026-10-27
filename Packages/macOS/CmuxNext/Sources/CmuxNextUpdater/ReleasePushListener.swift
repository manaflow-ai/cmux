import Foundation

/// The release push (Leo 2026-10-26: "if the nightly is post, I just want it. Just give it to me.
/// Don't wait... there should be some sort of hook, so you can just do the thing."). The scheduled
/// reads (``TipUpdateCheck``, Sparkle's own schedule) find a new build minutes to an hour after it
/// lands; this holds one WebSocket to the cmux-presence Worker's release feed, which sends a frame
/// the moment the feed's newest build changes, and starts the updater's own quiet check then.
///
/// Only for the app's own feed, when it is one the Worker serves (``feeds``); any other feed
/// (stable, RC, Intel, a test feed) connects nothing. ``UpdaterService`` runs it only while found
/// updates download and install by themselves (`updates.downloadAutomatically`, the #25283
/// opt-in) and `updates.checkAutomatically` is on; this type never reads a setting.
///
/// A frame acts only when its build is higher than the running build and than the last build it
/// acted on, so a reconnect's first frame (the same build again) or a duplicate starts nothing.
/// It never shows UI or activates the app: ``onNewerBuild`` hands the build to the updater, whose
/// fast check (``TipUpdateCheck``) reads the feed at once and starts the check its interval would;
/// the update flow decides what shows.
///
/// The connection task keeps this object while it runs, so its owner ends it with ``stop()``
/// (``UpdaterService`` does on every way the push stops, quit included).
///
/// Stop condition and cleanup: one connection task (``task``) runs while a feed is set
/// (``refresh(feedURL:)``). ``stop()`` (the opt-in or automatic checks off, the updater disabled,
/// the feed no longer served, and the app quitting) cancels the task, which ends the reconnect
/// sleep and the ping loop, and closes the socket with "going away". The ping loop lives only
/// while one socket is open and ends with it; a socket that leaves a ping unanswered for a whole
/// ``pingInterval`` is closed and reconnected. Reconnects back off from 1 s to at most 5 minutes
/// (``backoff(failures:jitter:)``) and reset once a connection hears a frame.
@MainActor
final class ReleasePushListener {
    /// The cmux-presence Worker that serves `/releases/v1/socket`.
    static let host = "presence.cmux.dev"
    /// The feeds the Worker serves, by the app's resolved feed URL (its allowlist, word for word).
    static let feeds: [String: String] = [
        "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml": "nightly-next",
        "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml": "tip",
    ]
    nonisolated static let pingInterval: Duration = .seconds(60)
    nonisolated static let minimumBackoff: TimeInterval = 1
    nonisolated static let maximumBackoff: TimeInterval = 300

    /// The Worker's feed id for `feedURL`, or nil (nothing connects).
    static func feedID(forFeedURL feedURL: String?) -> String? {
        feedURL.flatMap { feeds[$0] }
    }

    static func socketURL(feed: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/releases/v1/socket"
        components.queryItems = [URLQueryItem(name: "feed", value: feed)]
        return components.url
    }

    /// The wait before reconnecting after `failures` connections in a row heard nothing: doubling
    /// from 1 s, capped at 5 minutes, spread over the upper half of that by `jitter` (0...1).
    nonisolated static func backoff(failures: Int, jitter: Double) -> Duration {
        let ceiling = min(minimumBackoff * pow(2, Double(min(max(failures - 1, 0), 16))), maximumBackoff)
        let spread = min(max(jitter.isFinite ? jitter : 1, 0), 1)
        let seconds = max(minimumBackoff, ceiling * (0.5 + 0.5 * spread))
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    /// Opens a socket to `url` (live: ``LiveReleasePushSocket``; a fake in tests).
    var connect: @MainActor (URL) -> any ReleasePushSocket
    private let clock: any Clock<Duration>
    private let jitter: () -> Double
    private let log: (String) -> Void
    /// The running build, or nil when it is no integer (then nothing connects).
    let runningBuild: Int64?
    /// Starts the quiet check for a newer build (set by ``UpdaterService``).
    var onNewerBuild: ((Int64) -> Void)?
    /// The feed connected to, or nil.
    private(set) var feed: String?
    /// The newest build a frame acted on, and the feed it came from.
    private(set) var lastActed: Int64?
    private var lastActedFeed: String?
    private(set) var task: Task<Void, Never>?
    private(set) var socket: (any ReleasePushSocket)?
    /// Connections in a row that heard nothing (the backoff's exponent).
    private(set) var failures = 0
    /// A ping went out and nothing has come back since.
    private var awaitingPong = false

    init(runningBuild: String, clock: any Clock<Duration>, log: @escaping (String) -> Void,
         jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         connect: @escaping @MainActor (URL) -> any ReleasePushSocket = { LiveReleasePushSocket(url: $0) }) {
        self.runningBuild = Int64(runningBuild)
        self.clock = clock
        self.log = log
        self.jitter = jitter
        self.connect = connect
    }

    /// Follows the feed the app reads now, or nil when the push must not run: an allowlisted feed
    /// connects (a change of feed reconnects), anything else stops.
    func refresh(feedURL: String?) {
        let next = runningBuild == nil ? nil : Self.feedID(forFeedURL: feedURL)
        guard next != feed || (next != nil && task == nil) else { return }
        stop()
        guard let next, let url = Self.socketURL(feed: next) else { return }
        // The last build acted on belongs to the feed it came from.
        if lastActedFeed != next { lastActed = nil }
        lastActedFeed = next
        feed = next
        log("release push: listening on \(next)")
        task = Task { [weak self] in await self?.run(url: url, feed: next) }
    }

    /// Ends the connection task, its reconnects and its pings, and closes the socket.
    func stop() {
        guard task != nil || socket != nil else { feed = nil; return }
        task?.cancel()
        task = nil
        socket?.cancel()
        socket = nil
        feed = nil
        failures = 0
        log("release push: stopped")
    }

    private func run(url: URL, feed: String) async {
        // wakeup-allow: the reconnect loop; each pass waits on the socket's frames, then the capped backoff after it closes.
        while !Task.isCancelled {
            let socket = connect(url)
            self.socket = socket
            let heard = await listen(socket, feed: feed)
            socket.cancel()
            if self.socket === socket { self.socket = nil }
            guard !Task.isCancelled else { return }
            failures = heard ? 1 : failures + 1
            let delay = Self.backoff(failures: failures, jitter: jitter())
            log("release push: \(feed) socket closed; reconnecting in \(delay)")
            do { try await clock.sleep(for: delay) } catch { return } // wakeup-allow: the capped, jittered reconnect backoff (1 s to 5 min)
        }
    }

    /// Reads frames until the socket closes; true when it heard at least one.
    private func listen(_ socket: any ReleasePushSocket, feed: String) async -> Bool {
        awaitingPong = false
        let pings = Task { [weak self, clock] in
            // wakeup-allow: the release socket's keepalive while it is open; the Worker answers without waking its object.
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.pingInterval) } catch { return } // wakeup-allow: the 60 s ping interval
                guard let self, self.socket === socket else { return }
                if self.awaitingPong {
                    self.log("release push: no answer to the last ping; reconnecting")
                    return socket.cancel()
                }
                self.awaitingPong = true
                do { try await socket.send("ping") } catch { return socket.cancel() }
            }
        }
        defer { pings.cancel() }
        var heard = false
        // wakeup-allow: each pass waits for the next frame; it ends when the socket throws.
        while !Task.isCancelled {
            let text: String?
            do { text = try await socket.receive() } catch { return heard }
            // A frame that arrives after stop() (or after this socket was replaced) is not read.
            guard !Task.isCancelled, self.socket === socket else { return heard }
            heard = true
            // Only the Worker's answer to the ping proves the ping got through.
            if text == "pong" { awaitingPong = false }
            if let text { handle(text, feed: feed) }
        }
        return heard
    }

    /// A frame from the Worker: a release of this feed newer than the running build and than the
    /// last one acted on starts one check.
    func handle(_ text: String, feed: String) {
        guard text != "pong", let frame = ReleasePushFrame(text), frame.type == "release", frame.feed == feed,
              let runningBuild, frame.build > runningBuild else { return }
        if let lastActed, frame.build <= lastActed { return }
        lastActed = frame.build
        log("release push: build \(frame.build) on \(feed) is newer than build \(runningBuild): checking")
        onNewerBuild?(frame.build)
    }
}

/// One `{"type":"release","feed":…,"build":…}` frame (other fields are ignored).
nonisolated struct ReleasePushFrame: Decodable, Equatable {
    let type: String
    let feed: String
    let build: Int64

    init?(_ text: String) {
        guard let frame = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) else { return nil }
        self = frame
    }

    init(type: String, feed: String, build: Int64) {
        self.type = type
        self.feed = feed
        self.build = build
    }
}

/// The release socket (a fake in tests).
nonisolated protocol ReleasePushSocket: AnyObject, Sendable {
    /// The next frame's text (nil for a frame that is not text); throws once the socket closes.
    func receive() async throws -> String?
    func send(_ text: String) async throws
    /// Closes the socket; a pending ``receive()`` throws.
    func cancel()
}

/// A `URLSessionWebSocketTask` on its own ephemeral session, invalidated when the socket closes.
nonisolated final class LiveReleasePushSocket: ReleasePushSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        socket = session.webSocketTask(with: url)
        socket.resume()
    }

    func receive() async throws -> String? {
        switch try await socket.receive() {
        case .string(let text): text
        case .data(let data): String(data: data, encoding: .utf8)
        @unknown default: nil
        }
    }

    func send(_ text: String) async throws {
        try await socket.send(.string(text))
    }

    func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
