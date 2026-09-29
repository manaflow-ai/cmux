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
    private let destroyMachine: @MainActor (String) async throws -> Void
    private let didHide: @MainActor (String) -> Void
    private let didRetire: @MainActor (String) -> Void
    private let didRestore: @MainActor (String) -> Void
    private var requests: [String: Request] = [:]
    private var accountEpoch: UInt64 = 0
    private var accessDidEndObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - notificationCenter: Where `.cmuxCloudVMAccessDidEnd` is posted.
    ///   - destroyMachine: Sends the provider destroy request.
    ///   - didHide: Detaches the machine's local presentations: when a delete begins,
    ///     and when a create cleanup's request starts.
    ///   - didRetire: Closes the machine's registrations once its delete is confirmed,
    ///     and refreshes socket reads.
    ///   - didRestore: Lets creates keep the machine once its failed delete lists it again.
    init(
        notificationCenter: NotificationCenter = .default,
        destroyMachine: @escaping @MainActor (String) async throws -> Void = { try await VMClient.shared.destroy(id: $0) },
        didHide: @escaping @MainActor (String) -> Void = { MachineDeleteCoordinator.detachLocalPresentations(of: $0) },
        didRetire: @escaping @MainActor (String) -> Void = { MachineDeleteCoordinator.retireLocalPresentations(of: $0) },
        didRestore: @escaping @MainActor (String) -> Void = { MachineCreateCoordinator.shared.machineDeletionFailed($0) }
    ) {
        self.destroyMachine = destroyMachine
        self.didHide = didHide
        self.didRetire = didRetire
        self.didRestore = didRestore
        accessDidEndObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAccount() }
        }
    }

    /// Machines with a delete in flight, and this account's confirmed deletions.
    /// Reading it inside a view body or tracked closure observes changes.
    var hiddenMachineIDs: Set<String> { deletions.projection.hiddenMachineIDs }

    /// The hidden machines whose delete has not reported an outcome, the only
    /// ones whose rows can come back.
    var pendingMachineIDs: Set<String> { deletions.projection.pendingMachineIDs }

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
        didHide(machineID)
        return true
    }

    /// Hides the machine a cancelled create announced, for that create's cleanup.
    /// Its local presentations detach when the cleanup's destroy request starts.
    ///
    /// The create coordinator requests cleanup while it applies a transition: a
    /// cancel, before the create's card closes and for Cmd+W inside the close of the
    /// card's workspace, a cancelled create's late receipt, or an account's end. The
    /// request comes from the cleanup's own CLI process, so it reaches the socket
    /// after that transition has applied. A closed card has unbound any pane the
    /// person added, and the detach keeps that workspace instead of closing it whole
    /// or again. A cleanup whose CLI exits first lists the machine again with its
    /// presentations.
    /// - Parameter machineID: The exact provider machine identifier.
    func beginCleanup(_ machineID: String) {
        deletions.beginCleanup(machineID)
    }

    /// Stops the machine's creates, then closes its local workspaces and
    /// URL-backed panes, and refreshes socket reads.
    ///
    /// Creates stop first: closing a workspace cancels its create, and a create
    /// cancelled that way destroys the machine it names, even after this delete fails.
    /// - Parameters:
    ///   - machineID: The exact provider machine identifier.
    ///   - workspaceIDs: Finds the machine's local workspaces.
    ///   - creates: Stops the machine's creates, given those workspaces; nil uses
    ///     the shared create owner.
    ///   - closeWorkspaces: Closes the machine's local workspaces whole.
    ///   - closePanes: Closes the machine's URL-backed panes.
    ///   - republishSocketReads: Refreshes what socket reads answer. Closing a
    ///     background workspace posts no topology notification, and `cmux vm rm`
    ///     reaches the delete through a worker-lane `vm.destroy` call, which never
    ///     refreshes them.
    static func detachLocalPresentations(
        of machineID: String,
        workspaceIDs: @MainActor (String) -> Set<UUID> = { AppDelegate.shared?.localWorkspaceIDs(forCloudVMID: $0) ?? [] },
        creates: MachineCreateCoordinator? = nil,
        closeWorkspaces: @MainActor (String) -> Void = { AppDelegate.shared?.closeLocalWorkspaces(forCloudVMID: $0) },
        closePanes: @MainActor (String) -> Void = { SurfaceCatalog.shared.closeURLBackedPanes(on: .cloud($0)) },
        republishSocketReads: @MainActor () -> Void = { TerminalController.shared.externalTopologyDidChange() }
    ) {
        (creates ?? .shared).machineDeletionBegan(machineID, presentedIn: workspaceIDs(machineID))
        closeWorkspaces(machineID)
        closePanes(machineID)
        republishSocketReads()
    }

    /// Closes the local workspaces and URL-backed panes of a machine whose delete
    /// is confirmed, including any opened while the delete was pending, and
    /// refreshes socket reads.
    /// - Parameters:
    ///   - machineID: The exact provider machine identifier.
    ///   - closeRegistrations: Closes the machine's local workspaces and
    ///     unregisters its surface provider, which closes its URL-backed panes.
    ///   - republishSocketReads: Refreshes what socket reads answer, for the
    ///     same reasons as when the delete began.
    static func retireLocalPresentations(
        of machineID: String,
        closeRegistrations: @MainActor (String) -> Void = { AppDelegate.shared?.closeWorkspaces(forManagedCloudVMID: $0) },
        republishSocketReads: @MainActor () -> Void = { TerminalController.shared.externalTopologyDidChange() }
    ) {
        closeRegistrations(machineID)
        republishSocketReads()
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
        // A create's cleanup detaches the machine only once its request starts.
        if deletions.beginRequest(machineID) { didHide(machineID) }
        if let request = requests[machineID] { return try await request.task.value }
        let epoch = accountEpoch
        let token = UUID()
        let task = Task<Bool, Error> { @MainActor in
            let result: CloudMachineDeletionResult
            var failure: Error?
            do {
                try await self.destroyMachine(machineID)
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
        guard deletions.isPending(machineID), requests[machineID] == nil,
              deletions.finish(machineID, result: .failed) == .restored else { return }
        didRestore(machineID)
    }

    private func finish(_ machineID: String, result: CloudMachineDeletionResult, epoch: UInt64, token: UUID) {
        // An outcome that outlived its account neither restores nor retires anything.
        guard epoch == accountEpoch else { return }
        if requests[machineID]?.token == token { requests[machineID] = nil }
        switch deletions.finish(machineID, result: result) {
        case .retired:
            // Unregisters the machine's surface provider, which closes any URL-backed
            // pane opened since the delete began.
            didRetire(machineID)
        case .restored:
            didRestore(machineID)
        case .ignored:
            break
        }
    }

    /// Sign-out and account or team switches forget every deletion without
    /// rollback; requests still running finish without touching the new account.
    private func endAccount() {
        accountEpoch &+= 1
        requests.removeAll()
        deletions.endAccount()
    }
}
