import Foundation
import os

/// The Cloud Chief sockets' lifecycle, for the connectivity incident detector (PROTOCOL.md
/// "Connectivity incidents", surface `chief_cloud`). Each open conversation runs its own socket;
/// the observer gets every socket's changes, keyed by a per-socket id, and decides what the
/// sockets together mean (CmuxMobileLive `ServiceSockets`).
public final class ChiefCloudSocketSignals: Sendable {
    /// The app's one instance.
    public static let shared = ChiefCloudSocketSignals()

    public enum Signal: Sendable, Equatable {
        /// A dial started.
        case dialing
        /// The service welcomed the socket: it is live.
        case connected
        /// The socket ended; `wasLive` when it had been welcomed (a drop), else a failed dial.
        case ended(wasLive: Bool, reason: String)
        /// The socket is no longer wanted (its conversation closed, or the service refused it for good).
        case closed
    }

    public typealias Observer = @Sendable (_ socket: String, _ signal: Signal) -> Void

    init() {}

    // lint:allow lock - one observer slot, set at sign-in and read on each socket change.
    private let observer = OSAllocatedUnfairLock<(token: UUID, call: Observer)?>(initialState: nil)

    /// Makes `newObserver` the one observer; the token it returns stops it.
    public func observe(_ newObserver: @escaping Observer) -> UUID {
        let token = UUID()
        observer.withLock { $0 = (token, newObserver) }
        return token
    }

    /// Stops the observer `token` started, unless a newer one replaced it (a later sign-in).
    public func stopObserving(_ token: UUID) {
        observer.withLock { if $0?.token == token { $0 = nil } }
    }

    func emit(_ socket: String, _ signal: Signal) {
        let current = observer.withLock { $0?.call }
        current?(socket, signal)
    }
}
