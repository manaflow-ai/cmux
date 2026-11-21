public import Foundation

/// The arguments shared by the Cloud start-session action and its replayed ask.
/// Keeping this value in the Cloud domain leaves the App target responsible for action wiring only.
public struct CloudStartSessionRequest: Equatable, Sendable {
    public var machineID: String?
    public var name: String?
    public var agent: String
    public var cwd: String?
    public var fromFolder: String?
    public var model: String?
    /// The local model connection selected for this launch, independent of the account scope.
    public var connection: String?

    public init(machineID: String?, name: String?, agent: String, cwd: String?, fromFolder: String? = nil,
                model: String? = nil, connection: String? = nil) {
        (self.machineID, self.name, self.agent, self.cwd, self.fromFolder, self.model, self.connection) =
            (machineID, name, agent, cwd, fromFolder, model, connection)
    }

    /// The command that asks for this again, every word as the shell reads it back.
    public var command: String {
        var words = ["cmux cloud start-session"]
        if let machineID { words.append("--target machine:" + CloudStartCore.shellQuoted(machineID)) } else { words.append("--name " + CloudStartCore.shellQuoted(name ?? "")) }
        words.append("--agent " + agent + (model.map { " --model " + CloudStartCore.shellQuoted($0) } ?? ""))
        if let cwd { words.append("--cwd " + CloudStartCore.shellQuoted(cwd)) }
        if let fromFolder { words.append("--from-folder " + CloudStartCore.shellQuoted(fromFolder)) }
        if let connection { words.append("--connection " + CloudStartCore.shellQuoted(connection)) }
        return words.joined(separator: " ")
    }
}
