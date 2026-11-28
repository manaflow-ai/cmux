package import CmuxNextActions
package import CmuxNextCloud
import CmuxNextCloudStart
import Foundation

/// The named or automatic destination and the agent a Cloud session should open.
package struct CloudStartSessionRequest: Equatable {
    package struct Refusal: Error { package let message: String }

    package var machineID: String?
    package var name: String?
    package var agent: String
    package var cwd: String?
    package var fromFolder: String?
    package var model: String?

    package init(machineID: String? = nil, name: String? = nil, agent: String, cwd: String? = nil,
                 fromFolder: String? = nil, model: String? = nil) {
        (self.machineID, self.name, self.agent, self.cwd, self.fromFolder, self.model) = (machineID, name, agent, cwd, fromFolder, model)
    }

    /// The run's arguments, checked: `--agent` is a harness id, `--cwd` an absolute folder, `--from-folder` one on this Mac.
    @MainActor package static func parse(_ invocation: ActionInvocation, fromFolder: (ActionInvocation, String?) throws -> String?) throws -> Self {
        let checked = CloudStartCore().launchRun(agent: invocation["agent"]?.stringValue, cwd: invocation["cwd"]?.stringValue, name: invocation["name"]?.stringValue,
                                                 model: invocation["model"]?.stringValue, machineId: invocation.target.flatMap { $0.kind == .machine ? $0.id : nil })
        switch checked {
        case .failure(let invalid): throw Refusal(message: invalid == .cwd ? CloudStartSessionStrings.cwdInvalid : CloudStartSessionStrings.agentInvalid)
        case .success(let run): // the machine checks the model
            return Self(machineID: run.machineId, name: run.name, agent: run.agent, cwd: run.cwd, fromFolder: try fromFolder(invocation, run.cwd), model: run.model)
        }
    }

    /// The command that asks for this again, every word as the shell reads it back.
    package var command: String {
        CloudStartCore().launchCommand(.init(machineId: machineID, name: name, agent: agent, cwd: cwd, fromFolder: fromFolder, model: model))
    }

    package func asked(machine: String) -> CloudStartSessionStrings.Asked {
        CloudStartSessionStrings.Asked(machine: machine, agent: agent, command: command)
    }

    package var destinationName: String { name ?? "cloud-chats" }

    @MainActor package static func skipNamedRefresh() async {}

    @MainActor package func preflight(setup: CloudSetup, scheme: String, refreshNamed: @MainActor () async throws -> Void = Self.skipNamedRefresh,
                                     heldRefusal: (String) -> String? = { _ in nil }) async throws -> Self {
        if agent == "claude", machineID == nil, name != nil { try await refreshNamed() }
        let ready = agent == "claude" ? await setup.readyClaudeMachines(machine: machineID, name: machineID == nil ? name : nil).first : nil
        let (choice, refusal) = await setup.launchReadiness(harness: agent, model: model, readyClaude: ready != nil)
        let named = agent == "claude" ? setup.claudeMachine(named: destinationName) : nil
        let candidate = machineID ?? ready ?? named
        var request = self
        if machineID == nil, name == nil, choice == .claudeMachineLogin { request.machineID = ready }
        if let id = request.machineID ?? (name == nil && refusal != nil ? candidate : nil),
           let held = heldRefusal(id) { throw Refusal(message: held) }
        if let refusal, agent != "claude" || candidate == nil || (machineID == nil && name == nil) {
            throw Refusal(message: setupRequired(refusal, scheme: scheme, machine: candidate))
        }
        return request
    }

    /// Both setup and placement use only the current list to resolve a name.
    @MainActor package func requireFreshNamedList(
        isFresh: () -> Bool, refresh: @MainActor () async -> Void, check: () throws -> Void
    ) async throws {
        if !isFresh() { await refresh() }
        try check()
        guard isFresh() else {
            throw Refusal(message: CloudStartSessionStrings.listUnread(asked(machine: destinationName)))
        }
    }

    @MainActor package func freshNamedMachine<Machine>(
        isFresh: () -> Bool, refresh: @MainActor () async -> Void, check: () throws -> Void,
        find: (String) -> Machine?
    ) async throws -> Machine? {
        try await requireFreshNamedList(isFresh: isFresh, refresh: refresh, check: check)
        return find(destinationName)
    }

    @MainActor package func launchReadiness(setup: CloudSetup, machine: String) async -> (choice: CloudSetup.Choice, refusal: CloudSetup.Refusal?) {
        let ready = agent == "claude" ? await setup.readyClaudeMachines(machine: machine).contains(machine) : false
        return await setup.launchReadiness(harness: agent, model: model, readyClaude: ready)
    }

    package func setupRequired(_ refused: CloudSetup.Refusal, scheme: String, machine: String?) -> String {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "settings"
        link.path = "/" + refused.settingsRow.replacingOccurrences(of: ".", with: "/")
        if let machine { link.queryItems = [URLQueryItem(name: "machine", value: machine)] }
        else if refused.family == "claude", let name { link.queryItems = [URLQueryItem(name: "machineName", value: name)] }
        let explainLocalLogin = refused.family != "claude" && refused.localLogin
        return CloudStartSessionStrings.setupRequired(agent: agent, family: refused.family, localLogin: explainLocalLogin,
                                                      link: link.string ?? "", command: command, gatewayTeam: refused.gateway?.team,
                                                      gatewayCode: refused.gateway.map { $0.errorCode ?? "not_serving" })
    }
}
