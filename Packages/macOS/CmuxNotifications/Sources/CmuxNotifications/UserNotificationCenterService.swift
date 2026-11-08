@preconcurrency import Foundation
@preconcurrency public import UserNotifications

/// Serializes and bounds all UserNotifications framework entrypoints used by cmux.
///
/// Every call is funneled through one dedicated serial background queue and a
/// deadline. UserNotifications methods can block synchronously in XPC to
/// `usernotificationsd` before their completion handler is even wired up, and
/// they all barrier onto the app's single
/// `UNUserNotificationServiceConnection` queue. When the daemon wedges, one
/// blocked call therefore wedges every later call — so the whole surface must
/// live behind this boundary: the queue keeps the block off the callers'
/// executors, and the deadline turns an unbounded wait into a
/// ``UserNotificationCenterFailure/timedOut`` the caller can degrade on.
///
/// Safety: all stored properties are immutable after `init`; the queue and the
/// per-call ``UserNotificationCenterCallGate`` own every mutable interaction.
public final class UserNotificationCenterService: @unchecked Sendable {
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private let center: any UserNotificationCenterCalling
    private let operationQueue: DispatchQueue
    private let timeout: Duration
    private let sleep: Sleep

    /// Creates the production service around the current app's notification center.
    ///
    /// The serial dispatch queue is a deliberate legacy bridge: UserNotifications
    /// can block synchronously before returning from an otherwise callback-based
    /// method. Keeping that entrypoint on a dedicated GCD worker prevents it from
    /// occupying the main actor or Swift's cooperative executor.
    ///
    /// - Parameters:
    ///   - center: The notification center for the current application.
    ///   - timeout: Maximum time any queued call or completion may consume.
    public convenience init(
        center: UNUserNotificationCenter,
        timeout: Duration = .seconds(2)
    ) {
        let clock = ContinuousClock()
        self.init(
            center: center,
            operationQueue: DispatchQueue(
                label: "com.cmuxterm.user-notification-center",
                qos: .utility
            ),
            timeout: timeout,
            sleep: { duration in
                try await clock.sleep(for: duration)
            }
        )
    }

    init(
        center: any UserNotificationCenterCalling,
        operationQueue: DispatchQueue = DispatchQueue(
            label: "com.cmuxterm.user-notification-center.test",
            qos: .utility
        ),
        timeout: Duration,
        sleep: @escaping Sleep
    ) {
        self.center = center
        self.operationQueue = operationQueue
        self.timeout = timeout
        self.sleep = sleep
    }

    /// Installs the application delegate synchronously, as required before app launch returns.
    @MainActor
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        center.delegate = delegate
    }

    /// Installs notification categories through the bounded background boundary.
    /// - Parameter categories: Every category the application can deliver.
    /// - Returns: Success, a framework error, or a timeout.
    @MainActor
    public func setNotificationCategories(
        _ categories: Set<UNNotificationCategory>
    ) async -> Result<Void, UserNotificationCenterFailure> {
        await perform { [self] completion in
            center.setNotificationCategories(categories)
            completion(.success(()))
        }
    }

    /// Reads the currently registered notification categories through the
    /// bounded background boundary. Callers that maintain dynamic per-request
    /// categories (the Feed's `CMUXFeedQuestion.` namespace) merge against
    /// this snapshot inside their own serialized update chain.
    public func notificationCategories() async -> Result<
        Set<UNNotificationCategory>,
        UserNotificationCenterFailure
    > {
        await perform { [self] completion in
            center.getNotificationCategories { categories in
                completion(.success(categories))
            }
        }
    }

    /// Returns the app's current notification authorization status.
    public func authorizationStatus() async -> Result<
        UserNotificationAuthorizationStatus,
        UserNotificationCenterFailure
    > {
        await perform { [self] completion in
            center.getNotificationSettings { settings in
                completion(.success(UserNotificationAuthorizationStatus(settings.authorizationStatus)))
            }
        }
    }

    /// Requests notification authorization through the bounded background boundary.
    /// - Parameter options: The authorization capabilities requested from macOS.
    /// - Returns: Whether the user granted access, a framework error, or a timeout.
    public func requestAuthorization(
        options: UNAuthorizationOptions
    ) async -> Result<Bool, UserNotificationCenterFailure> {
        await perform { [self] completion in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    completion(.failure(.system(error.localizedDescription)))
                } else {
                    completion(.success(granted))
                }
            }
        }
    }

    /// Adds one notification request through the bounded background boundary.
    /// - Parameter request: The immutable request to submit to macOS.
    /// - Returns: Success, a framework error, or a timeout.
    public func add(
        _ request: UNNotificationRequest
    ) async -> Result<Void, UserNotificationCenterFailure> {
        await add(request) { [self] request, completion in
            center.add(request, withCompletionHandler: completion)
        }
    }

    /// Adds one notification request using an injected low-level entrypoint.
    ///
    /// The alternate entrypoint exists for app adapters and behavioral tests;
    /// it still uses this instance's single queue and deadline.
    ///
    /// - Parameters:
    ///   - request: The immutable request to submit.
    ///   - operation: The callback-based framework adapter to invoke.
    /// - Returns: Success, a framework error, or a timeout.
    public func add(
        _ request: UNNotificationRequest,
        using operation: @escaping UserNotificationAddOperation
    ) async -> Result<Void, UserNotificationCenterFailure> {
        await perform { completion in
            operation(request) { error in
                if let error {
                    completion(.failure(.system(error.localizedDescription)))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    /// Removes delivered notifications through the bounded background boundary.
    /// - Parameter identifiers: Request identifiers to remove.
    /// - Returns: Success or a timeout if the synchronous framework call wedges.
    public func removeDeliveredNotifications(
        withIdentifiers identifiers: [String]
    ) async -> Result<Void, UserNotificationCenterFailure> {
        guard !identifiers.isEmpty else { return .success(()) }
        return await perform { [self] completion in
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            completion(.success(()))
        }
    }

    /// Removes pending notification requests through the bounded background boundary.
    /// - Parameter identifiers: Request identifiers to remove.
    /// - Returns: Success or a timeout if the synchronous framework call wedges.
    public func removePendingNotificationRequests(
        withIdentifiers identifiers: [String]
    ) async -> Result<Void, UserNotificationCenterFailure> {
        guard !identifiers.isEmpty else { return .success(()) }
        return await perform { [self] completion in
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            completion(.success(()))
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (
            _ completion: @escaping @Sendable (
                Result<Value, UserNotificationCenterFailure>
            ) -> Void
        ) -> Void
    ) async -> Result<Value, UserNotificationCenterFailure> {
        await withCheckedContinuation { continuation in
            let gate = UserNotificationCenterCallGate(continuation: continuation)
            let timeoutTask = Task { [sleep, timeout] in
                do {
                    try await sleep(timeout)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                gate.resolve(.failure(.timedOut))
            }
            gate.installTimeoutTask(timeoutTask)
            operationQueue.async {
                guard gate.shouldStart() else { return }
                operation { result in
                    gate.resolve(result)
                }
            }
        }
    }
}

// Conformance lives in an extension so the `@MainActor` attribute on
// `UserNotificationCenterConfiguring` does not infer main-actor isolation for
// the whole service; only the two configuring witnesses are main-actor bound.
extension UserNotificationCenterService: UserNotificationCenterServing {}
