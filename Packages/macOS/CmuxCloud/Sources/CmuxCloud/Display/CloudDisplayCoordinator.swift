import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// Explicit display discovery/creation through the existing VM-authorized exec
/// route. Routine terminal catalog refreshes never execute guest commands.
@MainActor
@Observable
public final class CloudDisplayCoordinator {
    private let execute: @MainActor (String, Int) async throws -> VMExecResult
    public private(set) var snapshot: CloudGuestDisplaySnapshot?
    private(set) var lastValidatedSnapshot: CloudGuestDisplaySnapshot?
    public private(set) var isAvailable = false
    /// Becomes true after the first guest catalog probe completes, including a failed probe.
    /// Callers use this to keep creation enabled while discovery is still pending.
    public private(set) var hasAttemptedDiscovery = false
    private var generation: UInt64 = 0
    private var requestID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var creation: Task<CloudGuestDisplaySnapshot, Error>?

    public init(execute: @escaping @MainActor (String, Int) async throws -> VMExecResult) {
        self.execute = execute
    }

    public var canCreate: Bool { isAvailable && (snapshot?.canCreate == true || requestID != nil) && creation == nil }

    /// Creation needs no prior discovery: the guest's create reply is the
    /// authoritative catalog. Only a validated catalog that says the machine is
    /// full blocks a new request (a retained request id may still be retried).
    var allowsCreateRequest: Bool {
        requestID != nil || !(isAvailable && snapshot?.canCreate == false)
    }
    public var displaySnapshot: CloudGuestDisplaySnapshot? { snapshot ?? lastValidatedSnapshot }

    public func refresh() async {
        guard creation == nil else { return }
        refreshTask?.cancel()
        generation &+= 1
        let token = generation
        let task = Task { [weak self, execute] in
            do {
                var response: VMExecResult?
                var lastError: (any Error)?
                for attempt in 0..<3 {
                    do {
                        let candidate = try await execute(CloudGuestDisplayScript.command(action: "list"), 10_000)
                        if candidate.exitCode == 0 {
                            response = candidate
                            break
                        }
                        lastError = SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
                    } catch {
                        lastError = error
                    }
                    if attempt < 2 { try await Task.sleep(for: .milliseconds(100)) }
                }
                guard let response else { throw lastError ?? SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage) }
                guard response.exitCode == 0 else {
                    throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
                }
                let snapshot = try CloudGuestDisplaySnapshot(data: Data(response.stdout.utf8))
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.snapshot = snapshot
                self.lastValidatedSnapshot = snapshot
                self.isAvailable = true
            } catch {
                guard let self, token == self.generation else { return }
                self.snapshot = nil
                self.isAvailable = false
            }
        }
        refreshTask = task
        await task.value
        if token == generation { hasAttemptedDiscovery = true }
        if refreshTask != nil, token == generation { refreshTask = nil }
    }

    public func create() async throws -> CloudGuestDisplaySnapshot {
        if let creation {
            return try await withTaskCancellationHandler {
                try await creation.value
            } onCancel: {
                creation.cancel()
            }
        }
        guard allowsCreateRequest else {
            throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
        }
        // Creation supersedes any in-flight discovery; its reply carries the catalog.
        refreshTask?.cancel()
        refreshTask = nil
        generation &+= 1
        let token = generation
        let request = requestID ?? UUID()
        requestID = request
        // The UUID is generated here and retained after failures. A retry cannot
        // create a second guest display when the first receipt was lost.
        let task = Task { [weak self, execute] in
            try Task.checkCancellation()
            let response = try await execute(CloudGuestDisplayScript.command(action: "create", requestID: request), 65_000)
            let snapshot = try CloudGuestDisplaySnapshot(data: Data(response.stdout.utf8))
            try Task.checkCancellation()
            guard let self, self.generation == token else { throw CancellationError() }
            self.snapshot = snapshot
            self.lastValidatedSnapshot = snapshot
            self.isAvailable = true
            self.hasAttemptedDiscovery = true
            guard response.exitCode == 0, snapshot.error == nil, snapshot.created != nil else {
                throw SurfaceCatalogError.unsupported(String(localized: "cloud.display.creationFailed", defaultValue: "The new display could not start. Refresh Displays, then retry. Existing displays are unchanged."))
            }
            self.requestID = nil
            return snapshot
        }
        creation = task
        defer { if generation == token { creation = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func stop() {
        invalidate()
    }

    /// Drops guest state when the provider identity or account scope changes.
    public func invalidate() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        creation?.cancel()
        creation = nil
        snapshot = nil
        lastValidatedSnapshot = nil
        requestID = nil
        isAvailable = false
        hasAttemptedDiscovery = false
    }
}
