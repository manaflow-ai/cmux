package import CmuxNextCloud
package import CmuxNextDaemon
package import CmuxNextPages
import Foundation

/// Selects and prepares the owner's Cloud machine for the Settings sign-in.
@MainActor
package struct SettingsCloudClaudeLogin {
    private let host: SettingsCloudClaudeLoginHost

    package init(host: SettingsCloudClaudeLoginHost) { self.host = host }

    package struct Candidate {
        let record: CloudMachine
        let status: CloudMachine.Status
        let linked: Bool
        let supportsLogin: Bool

        package init(record: CloudMachine, status: CloudMachine.Status, linked: Bool, supportsLogin: Bool) {
            self.record = record
            self.status = status
            self.linked = linked
            self.supportsLogin = supportsLogin
        }
    }

    package enum MachineChoice: Equatable {
        case ready(String)
        case link(String)
        case create
        case unavailable
    }

    package static func pickMachine(_ candidates: [Candidate], owner: String?, personal: Bool,
                            preferred: String? = nil, requirePreferred: Bool = false, environment: String? = nil, name: String? = nil) -> MachineChoice {
        let owned = candidates.filter { candidate in
            let record = candidate.record
            guard environment == nil || record.environmentId == environment else { return false }
            guard name == nil || record.title == name else { return false }
            if personal { return CloudTransferRules.isOwner(record, user: owner) }
            // A record with no creator id may be the person's own: the link's owner answer decides after it connects.
            return CloudCallerOwnership(creator: record.createdBy, caller: owner) != .team
        }.sorted { $0.record.id < $1.record.id }
        if let name, !requirePreferred, candidates.contains(where: { $0.record.title == name }), owned.count != 1 {
            return .unavailable
        }
        let candidates = requirePreferred ? owned.filter { $0.record.id == preferred } : owned
        let linked = candidates.filter { $0.status == .running && $0.linked && $0.supportsLogin }
        if let ready = linked.first(where: { $0.record.id == preferred }) ?? linked.first {
            return .ready(ready.record.id)
        }
        // Paused, offline, or linked on an older daemon: connecting resumes it and waits out its update.
        if let offline = candidates.first(where: {
            [.paused, .running, .starting, .provisioning, .unknown].contains($0.status)
        }) {
            return .link(offline.record.id)
        }
        // Only teammates' machines (or none): the person gets their own.
        return requirePreferred || (name != nil && !candidates.isEmpty) ? .unavailable : .create
    }

    package func install(on models: SettingsModels, setup: CloudSetup) {
        models.cloudClaudeLogin = { state(preferred: $0, environment: $1, name: $2) }
        models.prepareCloudClaudeLogin = { try await prepare(preferred: $0, environment: $1, name: $2) }
        models.refreshCloudClaudeMachines = host.refreshMachines
        models.observeCloudClaudeAccount { host.account() }
        models.onCloudClaudeSignIn = { setup.claudeSignInCompleted(machine: $0) }
    }

    private func state(preferred: String?, environment: String?, name: String?) -> SettingsModels.CloudClaudeLogin {
        guard let account = host.account(), host.hasLoadedMachines(),
              case .ready(let id) = choice(preferred: preferred, requirePreferred: preferred != nil, environment: environment, name: name), let session = host.machine(id) else {
            return .connectable
        }
        return .ready(machine(session, account: account))
    }

    private func prepare(preferred: String?, environment: String?, name: String?) async throws -> SettingsModels.CloudClaudeMachine? {
        guard let account = host.account() else { throw CancellationError() }
        let check: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            guard host.account() == account else { throw CancellationError() }
        }
        let choose = { choice(preferred: preferred, requirePreferred: preferred != nil, environment: environment, name: name) }
        do {
            try check()
            if name != nil || !host.hasLoadedMachines() || [.create, .unavailable].contains(choose()) {
                guard await host.refreshMachines() else { throw Self.startFailure }
                try check()
            }
            guard host.hasLoadedMachines() else { throw Self.startFailure }

            let session: SettingsCloudClaudeMachineLink
            switch choose() {
            case .ready(let id), .link(let id):
                guard let existing = host.machine(id) else { throw Self.startFailure }
                session = existing
            case .unavailable:
                throw Self.startFailure
            case .create:
                guard let created = try await host.createMachine(environment, name, check) else { return nil }
                session = created
            }

            guard name == nil || session.candidate.record.title == name else { throw Self.startFailure }
            try await session.connect(check)
            let owner = await session.ownerLink()
            try check()
            guard session.linkHeld() else { throw Self.startFailure }
            guard owner != nil else {
                throw PageError(code: "cmux.models.shared_machine", message: "Cloud machine is shared")
            }
            guard session.supportsLogin() else {
                throw PageError(code: "cmux.models.unsupported", message: "Cloud machine does not support Settings sign-in")
            }
            return machine(session, account: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try check()
            throw (error as? PageError) ?? Self.startFailure
        }
    }

    package static var startFailure: PageError {
        PageError(code: "cmux.models.machine_start_failed", message: "Cloud machine start failed")
    }

    private func choice(preferred: String? = nil, requirePreferred: Bool = false, environment: String? = nil, name: String? = nil) -> MachineChoice {
        Self.pickMachine(host.machineIDs().compactMap { host.machine($0)?.candidate },
                         owner: host.caller(), personal: host.personal(), preferred: preferred, requirePreferred: requirePreferred, environment: environment, name: name)
    }

    private func machine(_ session: SettingsCloudClaudeMachineLink, account: [String?]) -> SettingsModels.CloudClaudeMachine {
        let id = session.candidate.record.id
        let scope: @MainActor @Sendable () -> Bool = {
            host.account() == account && host.machineIDs().contains(id)
        }
        let liveOwner = session.ownerLink
        let endpoint = session.endpoint
        let owner: AgentSessionAttachClient.OwnerLink = {
            guard !Task.isCancelled, let link = await liveOwner(), await scope() else { return nil }
            return link
        }
        return .init(id: id, name: session.candidate.record.title, environment: session.candidate.record.environmentId, request: { op, fields in
            try Task.checkCancellation()
            guard scope() else { throw CancellationError() }
            let link = await owner()
            try Task.checkCancellation()
            guard scope() else { throw CancellationError() }
            guard link != nil else { return Data(#"{"refused":{"reason":"shared_machine"}}"#.utf8) }
            let client = AgentSessionAttachClient(surface: 0, endpoint: endpoint)
            let reply: Data
            do {
                reply = try await client.settingsClaudeLogin(op, fields, ownerLink: owner)
            } catch {
                await client.close()
                throw error
            }
            await client.close()
            guard scope() else { throw CancellationError() }
            return reply
        }, openCallback: { url, owner, current in
            guard !Task.isCancelled, scope(), current() else { return false }
            return await session.openCallback(url, owner, { scope() && current() })
        })
    }
}
