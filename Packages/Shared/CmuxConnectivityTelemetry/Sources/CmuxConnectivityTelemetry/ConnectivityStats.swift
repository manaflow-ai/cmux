import Foundation
import os

/// Collects ``ConnectivityStat``s and sends them to the Cloud service in batches.
///
/// Code that timed a step calls ``add(_:)`` from any thread (no waiting). Stats wait in memory
/// (at most ``Configuration/capacity``, oldest dropped first) until ``flush()``: the app calls it
/// on a timer and when it goes to the background, and ``add(_:)`` starts one when a batch is full.
/// Everyone's stats carry no free text and are budgeted per hour; the team's carry their detail.
/// The service decides the tier again from the signed-in account, so this side only keeps
/// everyone's stats from ever holding text.
public final class ConnectivityStats: Sendable {
    /// What one upload answered.
    public enum UploadResult: Sendable, Equatable {
        /// Accepted: the batch is done.
        case sent
        /// Not now (offline, a 5xx, a rate limit, signed out): keep the batch for the next flush.
        case retryLater
        /// Refused for good (a 4xx the batch cannot fix): drop it.
        case discard
    }

    /// Sends one request body (`POST /v1/telemetry/connectivity`).
    public typealias Upload = @Sendable (Data) async -> UploadResult

    /// The app sending the stats.
    public struct Client: Sendable, Equatable {
        public var platform: String
        public var appVersion: String
        public var build: String
        public var osVersion: String
        /// dev, nightly, testflight or production.
        public var channel: String

        public init(platform: String, appVersion: String, build: String, osVersion: String, channel: String) {
            self.platform = platform
            self.appVersion = appVersion
            self.build = build
            self.osVersion = osVersion
            self.channel = channel
        }
    }

    public struct Configuration: Sendable, Equatable {
        /// Stats kept while they wait for an upload.
        public var capacity: Int = 200
        /// Stats in one request (the service accepts 50).
        public var batchSize: Int = 50
        /// Waiting stats that start a flush on their own.
        public var flushAt: Int = 20
        /// Everyone's stats per hour; the rest are counted, not kept.
        public var everyonePerHour: Int = 300

        public init() {}
    }

    private struct State: Sendable {
        var audience: ConnectivityAudience = .everyone
        var pending: [ConnectivityStat] = []
        var client: Client?
        var upload: Upload?
        var flushing = false
        var flushTimer = false
        var hourStart: Date?
        var keptThisHour = 0
        var dropped = 0
    }

    private let configuration: Configuration
    // lint:allow lock - add() is synchronous from any thread; the region only appends to an
    // array and reads the audience, never I/O; uploads run outside it.
    private let state: OSAllocatedUnfairLock<State>

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        state = OSAllocatedUnfairLock(initialState: State())
    }

    /// Where stats go. Until it is set, stats wait (within ``Configuration/capacity``).
    public func configure(client: Client, upload: @escaping Upload) {
        state.withLock { state in
            state.client = client
            state.upload = upload
        }
    }

    /// The audience stats are kept for. Leaving the team drops waiting stats, which may hold
    /// the team's detail.
    public func setAudience(_ next: ConnectivityAudience) {
        state.withLock { state in
            if state.audience == .team, next != .team { state.pending.removeAll() }
            state.audience = next
        }
    }

    /// Stats waiting for an upload, and how many were dropped so far (capacity, budget).
    public var waiting: (pending: Int, dropped: Int) {
        state.withLock { ($0.pending.count, $0.dropped) }
    }

    /// Keeps one stat for the next upload. Returns at once.
    public func add(_ stat: ConnectivityStat) {
        let start = state.withLock { state -> Bool in
            var stat = stat
            if state.audience != .team {
                if let hour = state.hourStart, stat.date.timeIntervalSince(hour) < 3600 {
                    guard state.keptThisHour < configuration.everyonePerHour else {
                        state.dropped += 1
                        return false
                    }
                } else {
                    // The first stat, or the first one an hour after the window opened.
                    state.hourStart = stat.date
                    state.keptThisHour = 0
                }
                state.keptThisHour += 1
                stat.fields = stat.fields.filter { $0.value.isFixedVocabulary }
            }
            state.pending.append(stat)
            if state.pending.count > configuration.capacity {
                state.dropped += state.pending.count - configuration.capacity
                state.pending.removeFirst(state.pending.count - configuration.capacity)
            }
            guard state.pending.count >= configuration.flushAt, state.upload != nil, !state.flushing else { return false }
            return true
        }
        // task-owner: one flush, ended when the queue is empty or an upload is refused.
        if start { Task.detached(priority: .utility) { [self] in await flush() } }
    }

    /// Flushes every `interval` for the life of the process (the first call starts it; later
    /// calls do nothing). The app also flushes when it goes to the background.
    public func flushPeriodically(every interval: Duration = .seconds(60), clock: any Clock<Duration> = ContinuousClock()) {
        let start = state.withLock { state -> Bool in
            defer { state.flushTimer = true }
            return !state.flushTimer
        }
        guard start else { return }
        // task-owner: the process's flush timer; runs for the life of the app (suspended with it).
        Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                await flush()
            }
        }
    }

    /// Sends waiting stats in batches until none are left or an upload asks to wait. Concurrent
    /// calls share one flush.
    public func flush() async {
        while true {
            let next = state.withLock { state -> (Data, Int, Upload)? in
                guard !state.flushing, let client = state.client, let upload = state.upload, !state.pending.isEmpty else {
                    return nil
                }
                state.flushing = true
                let count = min(configuration.batchSize, state.pending.count)
                let batch = Array(state.pending.prefix(count))
                return (Self.body(batch, client: client, audience: state.audience), count, upload)
            }
            guard let (body, count, upload) = next else { return }
            let result = await upload(body)
            let more = state.withLock { state -> Bool in
                state.flushing = false
                switch result {
                case .sent, .discard:
                    state.pending.removeFirst(min(count, state.pending.count))
                    return !state.pending.isEmpty
                case .retryLater:
                    return false
                }
            }
            if !more { return }
        }
    }

    /// The request body for a batch: `{schema, client, stats}`.
    static func body(_ stats: [ConnectivityStat], client: Client, audience: ConnectivityAudience) -> Data {
        let object: [String: Any] = [
            "schema": 1,
            "client": [
                "platform": client.platform,
                "app_version": client.appVersion,
                "build": client.build,
                "os_version": client.osVersion,
                "channel": client.channel,
            ],
            "stats": stats.map { $0.wire(for: audience) },
        ]
        // A dictionary of strings, numbers, flags and nested dictionaries always serializes.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
