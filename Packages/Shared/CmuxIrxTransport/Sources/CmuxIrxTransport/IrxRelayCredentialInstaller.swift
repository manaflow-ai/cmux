import Foundation

/// Serializes native credential installation. A failed local install retries
/// the latest credential without minting again or replacing the endpoint.
actor IrxRelayCredentialInstaller {
    typealias Install = @Sendable (IrxRelayCredential) async throws -> Void
    private let install: Install
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let journal: IrxJournal
    private var desired: [String: IrxRelayCredential] = [:]
    private var ownership: IrxRelayCredentialInstallOwnership?
    private var installed: [String: IrxRelayCredential]
    private var task: Task<Void, Never>?
    private var taskID = UUID()
    private var revision: UInt64 = 0
    private var sleeping = false
    private var stopped = false

    init(
        installed: [IrxRelayCredential],
        journal: IrxJournal,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        install: @escaping Install
    ) {
        self.installed = Self.index(installed)
        self.journal = journal
        self.now = now
        self.sleep = sleep
        self.install = install
    }

    func replace(with credentials: [IrxRelayCredential], ownership: IrxRelayCredentialInstallOwnership? = nil) {
        guard !stopped else { return }
        let next = Self.index(credentials)
        guard next != desired || self.ownership != ownership else { return }
        desired = next
        self.ownership = ownership
        revision &+= 1
        // Retain at most the current fleet. Native connections using a removed
        // relay can drain naturally; this cache does not retain its credential.
        installed = installed.filter { next[$0.key] != nil }
        if sleeping {
            task?.cancel()
            task = nil
            sleeping = false
        }
        guard task == nil else { return }
        taskID = UUID()
        let id = taskID
        task = Task { [weak self] in await self?.run(id: id) }
    }

    func stop() {
        stopped = true
        taskID = UUID()
        task?.cancel()
        task = nil
        desired.removeAll()
        installed.removeAll()
    }

    /// Waits for the current installation pass, including its retries, to finish.
    func waitUntilSettled() async {
        await task?.value
    }

    private func run(id: UUID) async {
        defer {
            if taskID == id {
                task = nil
                sleeping = false
            }
        }
        var failures = 0
        while !Task.isCancelled, !stopped, taskID == id {
            let observedRevision = revision
            let pending = desired.values.filter {
                $0.isUsable(at: now()) && installed[$0.relayURL] != $0
            }.sorted { $0.relayURL < $1.relayURL }
            guard !pending.isEmpty else { return }
            var failed = false
            for credential in pending {
                guard !Task.isCancelled, !stopped, taskID == id else { return }
                guard desired[credential.relayURL] == credential,
                      credential.isUsable(at: now()) else { continue }
                do {
                    guard try await install(credential, ownership: ownership) else {
                        if revision != observedRevision { break }
                        return
                    }
                    guard !Task.isCancelled, !stopped, taskID == id else { return }
                    installed[credential.relayURL] = credential
                    journal.record("endpoint", "relay-credential-installed", ["relay": credential.relayURL])
                } catch {
                    guard !Task.isCancelled, !stopped, taskID == id else { return }
                    failed = true
                    journal.record("endpoint", "relay-credential-install-retry", ["relay": credential.relayURL])
                }
            }
            // A fresher token that arrived during an install gets the next
            // turn immediately, after the old call has finished.
            if revision != observedRevision {
                failures = 0
                continue
            }
            guard failed else { return }
            let seconds = min(30, 1 << min(failures, 5))
            failures += 1
            sleeping = true
            do { try await sleep(.seconds(seconds)) }
            catch { return }
            guard taskID == id else { return }
            sleeping = false
        }
    }

    private func install(_ credential: IrxRelayCredential, ownership: IrxRelayCredentialInstallOwnership?) async throws -> Bool {
        guard let ownership else { try await install(credential); return true }
        let install = self.install
        let outcome = await ownership.gate.withCurrentMutation(ownership.generation) {
            do { try await install(credential); return IrxRelayCredentialMutationResult.success }
            catch { return IrxRelayCredentialMutationResult.failure(String(describing: error)) }
        }
        guard let outcome else {
            if await ownership.gate.isCurrent(ownership.generation) { throw InstallationFailure.retry }
            return false
        }
        switch outcome {
        case .success: return true
        case .failure: throw InstallationFailure.retry
        }
    }

    private enum InstallationFailure: Error { case retry }

    private static func index(_ credentials: [IrxRelayCredential]) -> [String: IrxRelayCredential] {
        var result: [String: IrxRelayCredential] = [:]
        for credential in credentials {
            if let previous = result[credential.relayURL], previous.expiresAt > credential.expiresAt { continue }
            result[credential.relayURL] = credential
        }
        return result
    }
}


/// Every retry must still belong to the autopilot that supplied its credential.
struct IrxRelayCredentialInstallOwnership: Sendable, Equatable {
    let gate: IrxRelayCredentialRotationGate
    let generation: UInt64

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.gate === rhs.gate && lhs.generation == rhs.generation
    }
}
