import AppKit
import CmuxNextAccounts
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextPages
import Foundation

/// Selects and prepares the owner's Cloud machine for the Settings sign-in.
@MainActor
struct SettingsCloudClaudeLogin {
    let services: AppServices
    weak var signInPane: SettingsSignInPane?
    private static let loginCapability = DaemonCapability.agentSessionLoginSettings.rawValue

    struct Candidate {
        let record: CloudMachine
        let status: CloudMachine.Status
        let linked: Bool
        let supportsLogin: Bool
    }

    enum MachineChoice: Equatable {
        case ready(String)
        case link(String)
        case create
    }

    static func pickMachine(_ candidates: [Candidate], owner: String?, personal: Bool,
                            preferred: String? = nil) -> MachineChoice {
        let owned = candidates.filter { candidate in
            let record = candidate.record
            if personal { return CloudTransferRules.isOwner(record, user: owner) }
            // A record with no creator id may be the person's own: the link's owner answer decides after it connects.
            return CloudCallerOwnership(creator: record.createdBy, caller: owner) != .team
        }.sorted { $0.record.id < $1.record.id }
        let linked = owned.filter { $0.status == .running && $0.linked && $0.supportsLogin }
        if let ready = linked.first(where: { $0.record.id == preferred }) ?? linked.first {
            return .ready(ready.record.id)
        }
        // Paused, offline, or linked on an older daemon: connecting resumes it and waits out its update.
        if let offline = owned.first(where: {
            [.paused, .running, .starting, .provisioning, .unknown].contains($0.status)
        }) {
            return .link(offline.record.id)
        }
        // Only teammates' machines (or none): the person gets their own.
        return .create
    }

    static func account(in services: AppServices) -> [String?]? {
        let cloud = services.cloud
        return cloud.auth.isSignedIn && !cloud.isSigningOut ? cloud.account : nil
    }

    func state(preferred: String?) -> SettingsModels.CloudClaudeLogin {
        guard let account = Self.account(in: services), services.cloud.hasLoadedCurrentMachines else {
            return .connectable
        }
        switch choice(preferred: preferred) {
        case .ready(let id):
            guard let session = services.machines.session(id) else { return .connectable }
            return .ready(machine(session, account: account))
        case .link, .create: return .connectable
        }
    }

    func prepare() async throws -> SettingsModels.CloudClaudeMachine? {
        guard let account = Self.account(in: services) else { throw CancellationError() }
        let cloud = services.cloud
        let asked = CloudStartSessionStrings.Asked(machine: "", agent: "claude", command: "Connect Claude on Cloud")
        let check = { [services] in
            try CloudStartSession.check(account, now: Self.account(in: services) ?? [], asked)
        }
        do {
            try check()
            if !cloud.hasLoadedCurrentMachines || choice() == .create {
                guard await cloud.refresh() else { throw Self.startFailure }
                try check()
            }
            guard cloud.hasLoadedCurrentMachines else { throw Self.startFailure }

            let session: CloudMachineSession
            switch choice() {
            case .ready(let id), .link(let id):
                guard let existing = services.machines.session(id) else { throw Self.startFailure }
                session = existing
            case .create:
                guard let created = try await create(checking: check) else { return nil }
                session = created
            }

            try await CloudStartSession(services: services).connected(session, byPerson: true, checking: check,
                                                                      failure: Self.startFailure)
            let owner = await session.appLink.ownerLink
            try check()
            guard session.linkHeld(), let identity = session.daemon.liveIdentity else { throw Self.startFailure }
            guard owner != nil else {
                throw PageError(code: "cmux.models.shared_machine", message: "Cloud machine is shared")
            }
            guard identity.supports(Self.loginCapability) else {
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

    private static var startFailure: PageError {
        PageError(code: "cmux.models.machine_start_failed", message: "Cloud machine start failed")
    }

    private func choice(preferred: String? = nil) -> MachineChoice {
        let cloud = services.cloud
        let candidates = cloud.listedMachineIDs.compactMap { id -> Candidate? in
            guard let session = services.machines.session(id) else { return nil }
            let identity = session.daemon.liveIdentity
            return Candidate(record: session.machine, status: session.effectiveStatus,
                             linked: identity != nil, supportsLogin: identity?.supports(Self.loginCapability) == true)
        }
        return Self.pickMachine(candidates, owner: cloud.auth.platformUserID, personal: services.accounts.agentKeys.isPersonal,
                                preferred: preferred)
    }

    private func create(checking check: () throws -> Void) async throws -> CloudMachineSession? {
        do {
            return try await services.cloud.createMachine(name: nil, startedByPerson: true, ownCreate: true, proceed: check)
        } catch CloudMachineCreateFlow.Failure.declined, CloudMachineCreateFlow.Failure.upgradeRequired(_), is CloudMachineCap.RunHere {
            return nil
        } catch let error where CloudMachineCap.refusal(error) != nil {
            return nil
        } catch {
            guard let refusal = CloudMachineCreation.proRefusal(error),
                  let window = signInPane?.window ?? services.windows.active?.window else { throw error }
            try check()
            let spec = CloudPresenter.planOfferSpec(refusal.message, plan: refusal.plan)
            let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
            try check()
            if answer.button == "confirm" {
                _ = await services.paidPlanUpgrade().start(plan: refusal.plan, source: .cloudRefusal, fallback: refusal.upgradeURL)
            }
            return nil
        }
    }

    private func machine(_ session: CloudMachineSession, account: [String?]) -> SettingsModels.CloudClaudeMachine {
        let id = session.machineID
        let liveOwner = CloudMachineLinks(appLink: session.appLink).ownerLink
        let endpoint = AgentTabRemoteHost.endpoint(on: session.daemon)
        let scope: @MainActor @Sendable () -> Bool = { [weak services] in
            guard let services else { return false }
            return Self.account(in: services) == account && services.cloud.listedMachineIDs.contains(id)
        }
        let owner: AgentSessionAttachClient.OwnerLink = {
            guard !Task.isCancelled, let link = await liveOwner(), await scope() else { return nil }
            return link
        }
        return .init(id: id, name: session.machine.title, request: { op, fields in
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
        }, openCallback: { [weak signInPane] url, browserOwner in
            guard !Task.isCancelled, scope() else { return false }
            return await signInPane?.open(url, owner: browserOwner, on: session.daemon) ?? false
        })
    }
}
