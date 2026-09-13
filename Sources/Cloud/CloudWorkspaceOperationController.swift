import Foundation
import os

/// Owns asynchronous Cloud workspace actions launched by synchronous AppKit entrypoints.
@MainActor
final class CloudWorkspaceOperationController {
    typealias Operation = @MainActor () async throws -> Void

    private let isAvailable: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var keyedTasks: [String: Task<Void, Never>] = [:]
    private var availabilityObservers: [NSObjectProtocol] = []

    init(
        isAvailable: @escaping @MainActor () -> Bool,
        notificationCenter: NotificationCenter = .default
    ) {
        self.isAvailable = isAvailable
        self.notificationCenter = notificationCenter
        availabilityObservers = [
            RightSidebarBetaFeatureSettings.didChangeNotification,
            .cmuxFeatureFlagsDidChange,
            .cmuxCloudVMAccessDidEnd
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.isAvailable() != true else { return }
                    self?.cancelAll()
                }
            }
        }
    }

    deinit {
        for observer in availabilityObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    var isCurrentlyAvailable: Bool { isAvailable() }

    @discardableResult
    func start(_ operation: @escaping Operation) -> Bool {
        guard isAvailable() else { return false }
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            do {
                try await operation()
            } catch is CancellationError {
                // Cancellation is the expected result of sign-out or disabling Cloud Machines.
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", category: "CloudWorkspace")
                    .error("Cloud workspace operation failed: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }

    /// Starts one keyed operation, dropping duplicate activations while the first
    /// operation is still restoring or focusing the remote workspace.
    @discardableResult
    func start(key: String, _ operation: @escaping Operation) -> Bool {
        guard isAvailable(), keyedTasks[key] == nil else { return false }
        let task = Task { @MainActor [weak self] in
            defer { self?.keyedTasks.removeValue(forKey: key) }
            do {
                try await operation()
            } catch is CancellationError {
                // Cancellation is the expected result of sign-out or disabling Cloud Machines.
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app", category: "CloudWorkspace")
                    .error("Keyed Cloud workspace operation failed: \(String(describing: error), privacy: .private)")
            }
        }
        keyedTasks[key] = task
        return true
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        for task in keyedTasks.values { task.cancel() }
        tasks.removeAll()
        keyedTasks.removeAll()
    }

    /// Waits for operations already submitted by a caller, primarily for integration tests.
    func waitForPendingOperations() async {
        for task in Array(tasks.values) { await task.value }
        for task in Array(keyedTasks.values) { await task.value }
    }
}
