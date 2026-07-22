public import Foundation
public import Observation

/// Owns readiness and queued navigation intent for one browser profile.
///
/// The executable supplies WebKit loading and a cancellable deadline. Consumers
/// observe ``updates()`` and execute only ``BrowserWebExtensionUpdate/navigationReleased(_:_:)``
/// events, which makes late load completion unable to replay an old intent.
@MainActor
@Observable
public final class BrowserWebExtensionProfileRuntime {
    /// The profile whose WebExtension state this runtime owns.
    public let profileID: UUID

    /// The current explicit lifecycle phase.
    public private(set) var phase: BrowserWebExtensionPhase = .idle

    /// The number of navigation intents still waiting for a readiness decision.
    public var pendingNavigationCount: Int { pendingNavigations.count }

    /// Whether the current loading generation is allowed to mutate WebKit.
    public private(set) var isLoadAttemptInFlight = false

    @ObservationIgnored
    private let waitForDeadline: @MainActor @Sendable () async throws -> Void
    @ObservationIgnored
    private var pendingNavigations: [UUID: BrowserWebExtensionNavigationIntent] = [:]
    @ObservationIgnored
    private var updateSubscribers: [UUID: UpdateSubscriber] = [:]
    @ObservationIgnored
    private var navigationUpdateHandler: (@MainActor (BrowserWebExtensionUpdate) -> Void)?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored
    private var generation: UInt64 = 0

    private struct UpdateSubscriber {
        let panelID: UUID?
        let continuation: AsyncStream<BrowserWebExtensionUpdate>.Continuation

        func accepts(_ update: BrowserWebExtensionUpdate) -> Bool {
            guard let panelID else { return true }
            guard case .actionChanged(let actionUpdate) = update else { return true }
            return actionUpdate.panelID == nil || actionUpdate.panelID == panelID
        }
    }

    /// Creates a runtime with an injected, testable loading deadline.
    ///
    /// - Parameters:
    ///   - profileID: The browser profile that owns this runtime.
    ///   - waitForDeadline: A cancellable operation that returns when the bounded deadline expires.
    public init(
        profileID: UUID,
        waitForDeadline: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        self.profileID = profileID
        self.waitForDeadline = waitForDeadline
    }

    /// Returns a typed stream beginning with the runtime's current phase.
    ///
    /// - Returns: A stream of lifecycle and exactly-once navigation updates.
    public func updates() -> AsyncStream<BrowserWebExtensionUpdate> {
        makeUpdates(panelID: nil, bufferingPolicy: .unbounded)
    }

    /// Returns a bounded latest-value stream filtered to one toolbar panel.
    public func presentationUpdates(
        for panelID: UUID
    ) -> AsyncStream<BrowserWebExtensionUpdate> {
        makeUpdates(panelID: panelID, bufferingPolicy: .bufferingNewest(32))
    }

    private func makeUpdates(
        panelID: UUID?,
        bufferingPolicy: AsyncStream<BrowserWebExtensionUpdate>.Continuation.BufferingPolicy
    ) -> AsyncStream<BrowserWebExtensionUpdate> {
        let continuationID = UUID()
        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            updateSubscribers[continuationID] = UpdateSubscriber(
                panelID: panelID,
                continuation: continuation
            )
            continuation.yield(.phaseChanged(phase))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.updateSubscribers.removeValue(forKey: continuationID)
                }
            }
        }
    }

    /// Installs the composition root's synchronous navigation observer.
    ///
    /// Navigation release and cancellation are delivered directly on the main
    /// actor so presentation stream backpressure can never drop an intent.
    public func setNavigationUpdateHandler(
        _ handler: (@MainActor (BrowserWebExtensionUpdate) -> Void)?
    ) {
        navigationUpdateHandler = handler
    }

    /// Starts or restarts extension loading for this profile.
    ///
    /// A restart cancels the previous deadline and loading task. Starting from
    /// a degraded phase is supported so a healthy retry can recover to ready.
    ///
    /// - Parameter load: The injected WebKit loading operation.
    public func start(
        load: @escaping @MainActor @Sendable () async -> BrowserWebExtensionLoadOutcome
    ) {
        guard phase != .shutDown else { return }
        generation &+= 1
        let currentGeneration = generation
        loadTask?.cancel()
        deadlineTask?.cancel()
        isLoadAttemptInFlight = true
        transition(to: .loading)

        loadTask = Task { @MainActor [weak self] in
            let outcome = await load()
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration,
                  self.phase != .shutDown else {
                return
            }
            self.isLoadAttemptInFlight = false
            self.deadlineTask?.cancel()
            self.deadlineTask = nil
            self.loadTask = nil
            switch outcome {
            case .ready:
                self.transition(to: .ready)
                self.releasePendingNavigations(reason: .ready)
            case .degraded(let failure):
                self.transition(to: .degraded(failure))
                self.releasePendingNavigations(reason: .loadFailed)
            }
        }

        deadlineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.waitForDeadline()
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.generation == currentGeneration,
                  self.phase == .loading else {
                return
            }
            // Expire the whole generation. Cooperative post-await checks in
            // the adapter prevent a loader that returns late from mutating
            // WebKit after a retry has started.
            self.generation &+= 1
            self.loadTask?.cancel()
            self.loadTask = nil
            self.isLoadAttemptInFlight = false
            self.deadlineTask = nil
            self.transition(to: .degraded(.loadDeadlineExceeded))
            self.releasePendingNavigations(reason: .deadlineExceeded)
        }
    }

    /// Queues an intent or releases it immediately when the runtime already permits navigation.
    ///
    /// - Parameter intent: The navigation intent owned by this profile.
    /// - Returns: `true` when the intent belonged to this runtime and was accepted.
    @discardableResult
    public func enqueueNavigation(_ intent: BrowserWebExtensionNavigationIntent) -> Bool {
        guard intent.profileID == profileID, phase != .shutDown else { return false }
        switch phase {
        case .ready:
            emit(.navigationReleased(intent, .ready))
        case .degraded(let failure):
            emit(.navigationReleased(
                intent,
                failure == .loadDeadlineExceeded ? .deadlineExceeded : .loadFailed
            ))
        case .idle, .loading:
            pendingNavigations[intent.id] = intent
        case .shutDown:
            return false
        }
        return true
    }

    /// Removes a queued navigation before the readiness decision releases it.
    ///
    /// - Parameter id: The navigation intent identifier.
    /// - Returns: `true` when a pending intent was removed.
    @discardableResult
    public func cancelNavigation(id: UUID) -> Bool {
        guard pendingNavigations.removeValue(forKey: id) != nil else { return false }
        emit(.navigationCancelled(id))
        return true
    }

    /// Publishes a typed toolbar action change through the profile stream.
    ///
    /// - Parameter update: The immutable action update to publish.
    public func publishActionUpdate(_ update: BrowserWebExtensionActionUpdate) {
        guard update.profileID == profileID, phase != .shutDown else { return }
        emit(.actionChanged(update))
    }

    /// Publishes an explicit optional-permission request.
    public func publishPermissionRequest(_ request: BrowserWebExtensionPermissionRequest) {
        guard request.profileID == profileID, phase != .shutDown else { return }
        emit(.permissionRequested(request))
    }

    /// Announces that installed extension or failure presentation changed.
    public func invalidateSnapshot() {
        guard phase != .shutDown else { return }
        emit(.snapshotInvalidated(profileID))
    }

    /// Terminates loading, deadlines, streams, and pending navigation state.
    public func shutdown() {
        guard phase != .shutDown else { return }
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoadAttemptInFlight = false
        deadlineTask?.cancel()
        deadlineTask = nil
        for id in pendingNavigations.keys {
            emit(.navigationCancelled(id))
        }
        pendingNavigations.removeAll()
        transition(to: .shutDown)
        for subscriber in updateSubscribers.values {
            subscriber.continuation.finish()
        }
        updateSubscribers.removeAll()
        navigationUpdateHandler = nil
    }

    private func transition(to newPhase: BrowserWebExtensionPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        emit(.phaseChanged(newPhase))
    }

    private func releasePendingNavigations(
        reason: BrowserWebExtensionNavigationReleaseReason
    ) {
        let intents = pendingNavigations.values.sorted { $0.id.uuidString < $1.id.uuidString }
        pendingNavigations.removeAll()
        for intent in intents {
            emit(.navigationReleased(intent, reason))
        }
    }

    private func emit(_ update: BrowserWebExtensionUpdate) {
        switch update {
        case .navigationReleased, .navigationCancelled:
            navigationUpdateHandler?(update)
        case .phaseChanged, .actionChanged, .snapshotInvalidated, .permissionRequested:
            break
        }
        for subscriber in updateSubscribers.values where subscriber.accepts(update) {
            subscriber.continuation.yield(update)
        }
    }
}
