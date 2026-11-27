import Foundation

/// One end of an agent session move: this Mac, or a host reached over SSH.
public enum AgentMoveEndpoint: Sendable, Equatable {
    /// The machine running the cmux CLI.
    case local
    /// A host reached with `ssh`.
    case ssh(AgentMoveSSHTarget)

    /// Whether this endpoint is the local machine.
    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    /// Human-readable name for messages: `local` or the SSH destination.
    public var displayName: String {
        switch self {
        case .local: return "local"
        case .ssh(let target): return target.destination
        }
    }

    /// The invocation that runs a POSIX `sh` script on this endpoint.
    ///
    /// Remote scripts are sent on standard input to `sh -s`, so the user's login
    /// shell (fish, csh, tcsh, ...) only parses `sh -s` and never the script. The
    /// script is one brace group reading `/dev/null`: `sh` parses the whole group
    /// before running it, so no command inside can consume the rest of the script.
    public func shellInvocation(_ script: String) -> AgentMoveInvocation {
        switch self {
        case .local:
            return AgentMoveInvocation(arguments: ["/bin/sh", "-c", script])
        case .ssh(let target):
            return AgentMoveInvocation(
                arguments: ["ssh"] + target.sshArguments + ["--", target.destination, "sh -s"],
                standardInput: "{\n\(script)\n} </dev/null\n"
            )
        }
    }

    /// A path in the form `rsync` and `git` accept for this endpoint (`host:path` for SSH).
    public func transferPath(_ path: String) -> String {
        switch self {
        case .local: return path
        case .ssh(let target): return "\(target.destination):\(path)"
        }
    }
}

/// An SSH destination plus the connection flags `cmux ssh` also accepts.
public struct AgentMoveSSHTarget: Sendable, Equatable, Codable {
    /// `user@host` or an `ssh_config` alias.
    public var destination: String
    /// Optional SSH port.
    public var port: String?
    /// Optional identity file.
    public var identityFile: String?
    /// Extra `-o` options.
    public var options: [String]

    /// Creates a target.
    public init(destination: String, port: String? = nil, identityFile: String? = nil, options: [String] = []) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.options = options
    }

    /// Whether every value can be passed through `rsync -e` and `GIT_SSH_COMMAND` unquoted.
    ///
    /// `rsync -e` splits its argument on whitespace, so values containing whitespace
    /// are refused rather than quoted differently per rsync implementation.
    public var isTransportSafe: Bool {
        let values = [destination] + [port, identityFile].compactMap { $0 } + options
        return !destination.isEmpty
            && !destination.hasPrefix("-")
            && !destination.contains("://")
            && values.allSatisfy { value in !value.contains(where: { $0.isWhitespace }) }
    }

    /// `ssh` flags (without the program name and destination).
    public var sshArguments: [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=30"]
        if let port { arguments += ["-p", port] }
        if let identityFile { arguments += ["-i", identityFile] }
        for option in options { arguments += ["-o", option] }
        return arguments
    }

    /// The `ssh` command line for `rsync -e` and `GIT_SSH_COMMAND`.
    public var sshCommandLine: String {
        (["ssh"] + sshArguments).joined(separator: " ")
    }
}

/// POSIX shell single-quoting.
public struct AgentMoveShellQuoting: Sendable {
    /// Creates a quoter.
    public init() {}

    /// Quotes `value` as one POSIX shell word.
    public func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
