import CmuxCloud
import CmuxCloudMachines
import Foundation

/// Adapts the shared deletion owner to the destroy request, local workspaces, and panes.
/// Every Delete Machine entrypoint starts here, and every machine list omits
/// `hiddenMachineIDs`, so a confirmed delete leaves every surface in the same frame.
@MainActor
final class MachineDeleteCoordinator {
    static let shared = MachineDeleteCoordinator()

    private struct Request {
        let token: UUID
        let task: Task<Bool, Error>
    }

    private let deletions = CloudMachineDeletionCoordinator()
    private var requests: [String: Request] = [:]
    private var accountEpoch: UInt64 = 0
    private var accessDidEndObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        accessDidEndObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAccount() }
        }
    }

    /// Machines with a delete in flight, and this account's confirmed deletions.
    /// Reading it inside a view body or tracked closure observes changes.
    var hiddenMachineIDs: Set<String> { deletions.projection.hiddenMachineIDs }

    /// Whether a new delete of the machine may start.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False while the machine is being, or has been, deleted.
    func canBegin(_ machineID: String) -> Bool {
        !machineID.isEmpty && !hiddenMachineIDs.contains(machineID)
    }

    /// Hides the machine everywhere and closes its local presentations before
    /// any destroy request is sent.
    ///
    /// Closing is a local detach: the machine and its terminals keep running and
    /// its surface provider stays registered, so after a failed delete the
    /// restored row opens the machine again.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: False when a delete of the machine already began.
    @discardableResult
    func begin(_ machineID: String) -> Bool {
        guard deletions.begin(machineID) else { return false }
        AppDelegate.shared?.closeLocalWorkspaces(forCloudVMID: machineID)
        SurfaceCatalog.shared.closeURLBackedPanes(on: .cloud(machineID))
        MachineCreateCoordinator.shared.machineDeletionBegan(machineID)
        return true
    }

    /// Destroys the machine for the `vm.destroy` socket method, which every
    /// entrypoint's `cmux vm rm` reaches. A repeated call joins the request in
    /// flight, and a confirmed deletion answers without another request.
    /// - Parameter machineID: The exact provider machine identifier.
    /// - Returns: True when the provider no longer knew the machine.
    /// - Throws: The provider's error; the machine is listed again.
    func destroy(id machineID: String) async throws -> Bool {
        if hiddenMachineIDs.contains(machineID), !deletions.isPending(machineID) { return true }
        begin(machineID)
        if let request = requests[machineID] { return try await request.task.value }
        let epoch = accountEpoch
        let token = UUID()
        let task = Task<Bool, Error> { @MainActor in
            let result: CloudMachineDeletionResult
            var failure: Error?
            do {
                try await VMClient.shared.destroy(id: machineID)
                result = .deleted
            } catch VMClientError.httpStatus(404, _) {
                // Delete is idempotent from the person's perspective: a machine the
                // backend already forgot is gone, never an error sheet.
                result = .notFound
            } catch {
                result = .failed
                failure = error
            }
            self.finish(machineID, result: result, epoch: epoch, token: token)
            if let failure { throw failure }
            return result == .notFound
        }
        requests[machineID] = Request(token: token, task: task)
        return try await task.value
    }

    /// Restores a machine whose `cmux vm rm` process exited before its destroy
    /// request reported an outcome, such as a CLI that never reached the socket.
    /// The launcher presents the failure.
    /// - Parameter machineID: The machine the process was deleting.
    func launchEnded(_ machineID: String) {
        guard deletions.isPending(machineID), requests[machineID] == nil else { return }
        _ = deletions.finish(machineID, result: .failed)
    }

    private func finish(_ machineID: String, result: CloudMachineDeletionResult, epoch: UInt64, token: UUID) {
        // An outcome that outlived its account neither restores nor retires anything.
        guard epoch == accountEpoch else { return }
        if requests[machineID]?.token == token { requests[machineID] = nil }
        guard deletions.finish(machineID, result: result) == .retired else { return }
        // Unregisters the machine's surface provider, which closes any URL-backed
        // pane opened since the delete began.
        AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: machineID)
    }

    /// Sign-out and account or team switches forget every deletion without
    /// rollback; requests still running finish without touching the new account.
    private func endAccount() {
        accountEpoch &+= 1
        requests.removeAll()
        deletions.endAccount()
    }
}
