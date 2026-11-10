import CmuxNextCompat
public import CmuxNextDaemon
public import Foundation

/// Where the Channels page reaches this build's Chief conversations: the
/// loopback page listener of this build's Chief home's conversation owner
/// (`ChiefHome` of this bundle, never another build's), with a credential
/// bound to that page (`page-credential {page}`, `page-credential-scoped-v1`).
///
/// The owner's app connection is a trusted local connection but not the
/// verified app, so it gets no person credential and no Cloud lease. The
/// scoped credential admits one handshake with the page's Origin only, so the
/// owner's page-router table applies to the page, and it is never the
/// person: Cloud conversations stay on the build's own daemon. The page asks
/// again on every reconnect (single use, 2 min).
public nonisolated struct ChiefOwnerPageEndpoint: Sendable, Equatable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

extension ChiefConversationOwner {
    /// What the Channels page gets from this owner.
    public enum PageEndpointOutcome: Sendable, Equatable {
        /// The owner's listener and a credential bound to the page.
        case ready(ChiefOwnerPageEndpoint)
        /// The owner is starting or reconnecting: the page tries again.
        case starting
        /// No owner endpoint (too old, refused, or never started): the page uses the build
        /// daemon only, as before, never a dead end.
        case unavailable
    }

    /// How long a page's credential call holds for an owner that is starting (``pageEndpoint(page:waitingUpTo:clock:)``):
    /// past it the page's own retries take over, well inside the grace before it says it is connecting (25 s).
    public static let pageStartWait: Duration = .seconds(15)

    /// ``pageEndpoint(page:)`` once a starting owner is connected. A fresh profile's first launch spawns
    /// the owner while Home's Messages page loads; answering `.starting` at once left the page to its
    /// doubling retry delays (0.5 s, 1 s, 2 s, 4 s…), blank the whole time, so the first window showed no
    /// Chief chat and no Set Up cmux card seconds after the owner was up. The call now waits on the
    /// owner's connection (an observation, bounded by `limit`) and answers the moment it is there.
    public func pageEndpoint(page: String, waitingUpTo limit: Duration,
                             clock: any Clock<Duration> = ContinuousClock()) async -> PageEndpointOutcome {
        if connection == nil, isRunning {
            _ = await OwnerStartWait(limit: limit, clock: clock).holds { [weak self] in self?.connection != nil }
        }
        return await pageEndpoint(page: page)
    }

    /// The page `page`'s endpoint on this owner. While the owner starts or reconnects the page
    /// waits for it (it would show the wrong conversations otherwise); a refusal or an owner
    /// that cannot start leaves the page on the build daemon.
    public func pageEndpoint(page: String) async -> PageEndpointOutcome {
        guard let connection else { return isRunning ? .starting : .unavailable }
        guard supports(DaemonCapability.wsListen.rawValue),
              supports(DaemonCapability.scopedPageCredential.rawValue) else { return .unavailable }
        do {
            // The owner's listener admits this page's Origin only (loopback, like the build daemon's).
            let listener = try await connection.request(WsListenRequest(allowOrigin: "cmux-page://cmux.\(page)"))
            let credential = try await connection.request(ScopedPageCredentialRequest(page: page))
            return .ready(ChiefOwnerPageEndpoint(url: listener.url, token: credential.credential))
        } catch let error as DaemonError where error.isLostConnection {
            return .starting
        } catch {
            return .unavailable
        }
    }
}

/// A bounded wait for main-actor state: whether `condition` holds within `limit` (an observation,
/// raced against one deadline on `clock`). It answers as soon as the condition holds, never on a poll.
@MainActor
public struct OwnerStartWait {
    public let limit: Duration
    private let clock: any Clock<Duration>

    public init(limit: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        self.clock = clock
    }

    /// Whether `condition` holds within ``limit``.
    public func holds(until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        return await Self.race(limit, clock, condition)
    }

    /// The observation against one deadline on `clock` (the injected clock, opened to its type).
    private static func race<C: Clock>(_ limit: Duration, _ clock: C,
                                       _ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool where C.Duration == Duration {
        // concurrency-allow: both children end with the group (the observation exits on cancellation); this bounds a page's credential call
        await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for an owner that never connects; the page's retries take over after it
                try? await clock.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }
}
