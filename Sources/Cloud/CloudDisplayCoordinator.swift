import Foundation
import Observation

/// Explicit display discovery/creation through the existing VM-authorized exec
/// route. Routine terminal catalog refreshes never execute guest commands.
@MainActor
@Observable
final class CloudDisplayCoordinator {
    private let execute: @MainActor (String, Int) async throws -> VMExecResult
    private(set) var snapshot: CloudGuestDisplaySnapshot?
    private(set) var isAvailable = false
    private var generation: UInt64 = 0
    private var requestID: UUID?
    private var creation: Task<CloudGuestDisplaySnapshot, Error>?

    init(execute: @escaping @MainActor (String, Int) async throws -> VMExecResult) {
        self.execute = execute
    }

    var canCreate: Bool { isAvailable && (snapshot?.canCreate == true || requestID != nil) && creation == nil }

    func refresh() async {
        guard creation == nil else { return }
        generation &+= 1
        let token = generation
        do {
            let response = try await execute("/usr/local/bin/cmux-display list", 10_000)
            let snapshot = try CloudGuestDisplaySnapshot(data: Data(response.stdout.utf8))
            guard token == generation, !Task.isCancelled else { return }
            self.snapshot = snapshot
            isAvailable = response.exitCode == 0
        } catch {
            guard token == generation else { return }
            isAvailable = false
        }
    }

    func create() async throws -> CloudGuestDisplaySnapshot {
        if let creation { return try await creation.value }
        guard isAvailable, snapshot?.canCreate == true || requestID != nil else {
            throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
        }
        generation &+= 1
        let token = generation
        let request = requestID ?? UUID()
        requestID = request
        // The UUID is generated here and retained after failures. A retry cannot
        // create a second guest display when the first receipt was lost.
        let task = Task { [weak self, execute] in
            try Task.checkCancellation()
            let response = try await execute("/usr/local/bin/cmux-display create --request-id \(request.uuidString.lowercased())", 65_000)
            let snapshot = try CloudGuestDisplaySnapshot(data: Data(response.stdout.utf8))
            try Task.checkCancellation()
            guard let self, self.generation == token else { throw CancellationError() }
            self.snapshot = snapshot
            guard response.exitCode == 0, snapshot.error == nil, snapshot.created != nil else {
                throw SurfaceCatalogError.unsupported(String(localized: "cloud.display.creationFailed", defaultValue: "The new display could not start. Refresh Displays, then retry. Existing displays are unchanged."))
            }
            self.requestID = nil
            return snapshot
        }
        creation = task
        defer { if generation == token { creation = nil } }
        return try await task.value
    }

    func stop() {
        generation &+= 1
        creation?.cancel()
        creation = nil
        isAvailable = false
    }
}
