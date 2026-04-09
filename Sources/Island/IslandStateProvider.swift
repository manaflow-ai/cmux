// Sources/Island/IslandStateProvider.swift

import Combine
import Foundation

/// Downstream interface the island SwiftUI view depends on.
///
/// The view observes `sessionsPublisher` and re-renders whenever it emits.
/// Keeping the view's only dependency on this protocol is what lets the
/// production store be swapped for an in-memory fake (tests + debug menu)
/// or a future `SocketIslandStateProvider` (Phase 3 companion app).
protocol IslandStateProvider: AnyObject {
    /// Emits the current flat, sorted list of active agent sessions.
    /// Empty list means the island should be hidden.
    var sessionsPublisher: AnyPublisher<[IslandSession], Never> { get }

    /// Snapshot of the most recent emission, for callers that need a pull
    /// API alongside the publisher.
    var currentSessions: [IslandSession] { get }
}

// MARK: - Upstream source (the store's input)

/// Upstream interface. The store subscribes to a single "tick" publisher
/// that fires whenever any of (workspace list, per-workspace status entries,
/// per-panel notifications) change, and the store pulls a fresh snapshot.
///
/// This is deliberately narrower than `TabManager` so the store is testable
/// with an in-memory fake that doesn't need Workspace/TabManager at all.
protocol IslandStateSource: AnyObject {
    /// Fires whenever anything relevant to the projection changes.
    var changes: AnyPublisher<Void, Never> { get }

    /// Pull a fresh `[IslandSession]` snapshot. Must be callable on the
    /// main actor — sources that read AppKit state should hop internally.
    @MainActor
    func makeSnapshot() -> [IslandSession]
}

// MARK: - In-memory source for tests and debug injection

final class InMemoryIslandStateSource: IslandStateSource {
    private let subject = PassthroughSubject<Void, Never>()

    @MainActor
    private(set) var sessions: [IslandSession] = [] {
        didSet { subject.send(()) }
    }

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    @MainActor
    func makeSnapshot() -> [IslandSession] { sessions }

    @MainActor
    func set(_ sessions: [IslandSession]) {
        self.sessions = sessions
    }

    @MainActor
    func add(_ session: IslandSession) {
        sessions.append(session)
    }

    @MainActor
    func clear() {
        sessions.removeAll()
    }
}
