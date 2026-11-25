package import CmuxNextActions
package import CmuxNextCloud
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
        let agent = invocation["agent"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard !agent.isEmpty, agent.utf8.count <= 64, agent.unicodeScalars.allSatisfy(allowed.contains), let first = agent.first, first.isLetter || first.isNumber else {
            throw Refusal(message: CloudStartSessionStrings.agentInvalid)
        }
        var cwd = invocation["cwd"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        if cwd?.isEmpty == true { cwd = nil }
        if let cwd, !cwd.hasPrefix("/") || cwd.utf8.count > 4096 || cwd.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw Refusal(message: CloudStartSessionStrings.cwdInvalid)
        }
        let machineID = invocation.target.flatMap { $0.kind == .machine ? $0.id : nil }
        let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        return Self(machineID: machineID, name: name?.isEmpty == false ? name : nil, agent: agent, cwd: cwd, fromFolder: try fromFolder(invocation, cwd), model: invocation["model"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }) // the machine checks the model
    }

    package var command: String {
        var words = ["cmux cloud start-session"]
        if let machineID { words.append("--target machine:" + CloudStartCore.shellQuoted(machineID)) }
        else if let name { words.append("--name " + CloudStartCore.shellQuoted(name)) }
        words.append("--agent " + agent + (model.map { " --model " + CloudStartCore.shellQuoted($0) } ?? ""))
        if let cwd { words.append("--cwd " + CloudStartCore.shellQuoted(cwd)) }
        if let fromFolder { words.append("--from-folder " + CloudStartCore.shellQuoted(fromFolder)) }
        return words.joined(separator: " ")
    }

    package func asked(machine: String) -> CloudStartSessionStrings.Asked {
        CloudStartSessionStrings.Asked(machine: machine, agent: agent, command: command)
    }

    package var destinationName: String { name ?? "cloud-chats" }

    @MainActor package func preflight(setup: CloudSetup, scheme: String, heldRefusal: (String) -> String? = { _ in nil }) async throws -> Self {
        let ready = agent == "claude" ? await setup.readyClaudeMachines(machine: machineID, name: machineID == nil ? name : nil).first : nil
        var request = self
        let named = agent == "claude" ? setup.claudeMachine(named: destinationName) : nil
        let fallback = machineID == nil && name == nil && ready == nil ? named : nil
        request.machineID = machineID ?? ready ?? named
        if let id = request.machineID, let held = heldRefusal(id) { throw Refusal(message: held) }
        if let refused = await setup.refusal(harness: agent, model: model, readyClaude: ready != nil),
           agent != "claude" || request.machineID == nil || fallback != nil {
            throw Refusal(message: setupRequired(refused, scheme: scheme, machine: request.machineID))
        }
        return request
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
                                                      link: link.string ?? "", command: command)
    }
}
