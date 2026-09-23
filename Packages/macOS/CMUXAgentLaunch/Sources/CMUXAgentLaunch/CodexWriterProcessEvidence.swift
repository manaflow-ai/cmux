import Foundation

/// Process identity evidence collected while diagnosing a Codex writer lock.
public struct CodexWriterProcessEvidence: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let startTime: String?
    let command: String
    public let executablePath: String?
    let arguments: [String]
    let pidVersion: UInt32?
    let isPrivateCmuxServer: Bool
    let hasConnectedClients: Bool
    let hasControllingTerminal: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        command: String,
        startTime: String? = nil,
        executablePath: String? = nil,
        arguments: [String]? = nil,
        pidVersion: UInt32? = nil,
        isPrivateCmuxServer: Bool = false,
        hasConnectedClients: Bool = true,
        hasControllingTerminal: Bool = true
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.command = command
        self.executablePath = executablePath
        self.arguments = arguments ?? command.split(whereSeparator: \.isWhitespace).map(String.init)
        self.pidVersion = pidVersion
        self.isPrivateCmuxServer = isPrivateCmuxServer
        self.hasConnectedClients = hasConnectedClients
        self.hasControllingTerminal = hasControllingTerminal
    }

    public var appServerPort: Int? {
        guard isCodexAppServer else { return nil }
        guard arguments.count == 4, arguments[2] == "--listen" else {
            return nil
        }
        return Self.port(from: arguments[3])
    }

    public var watcherAppServerPort: Int? {
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--socket" || arguments[index] == "--password" else { break }
            guard index + 1 < arguments.count else { return nil }
            index += 2
        }
        guard index < arguments.count, arguments[index] == "__codex-teams-watch" else { return nil }
        let watcherArguments = Array(arguments.dropFirst(index + 1))
        guard let endpoint = optionValue(named: "--app-server-url", in: watcherArguments) else {
            return nil
        }
        return Self.port(from: endpoint)
    }

    public var isCodexAppServer: Bool {
        guard executableBasename == "codex" else { return false }
        return arguments.dropFirst().first == "app-server"
    }

    public var validatedExecutableName: String? {
        return executableBasename
    }

    private var executableBasename: String? {
        guard let executablePath else { return nil }
        let basename = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return basename.isEmpty ? nil : basename
    }

    private func optionValue(named name: String, in parts: [String]) -> String? {
        if let inline = parts.first(where: { $0.hasPrefix(name + "=") }) {
            return String(inline.dropFirst(name.count + 1))
        }
        guard let index = parts.firstIndex(of: name), index + 1 < parts.count else {
            return nil
        }
        return parts[index + 1]
    }

    private static func port(from endpoint: String) -> Int? {
        guard let components = URLComponents(string: endpoint),
              components.scheme == "ws",
              components.host == "127.0.0.1",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty,
              let port = components.port,
              (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}

/// Classifies a holder without applying a termination policy.
public struct CodexWriterRecoveryAssessment: Equatable, Sendable {
    public enum Classification: Equatable, Sendable {
        case orphanedAppServer
        case ownedAppServer
        case other
    }

    public let holder: CodexWriterProcessEvidence
    public let classification: Classification

    public init(holder: CodexWriterProcessEvidence, watchedAppServerPorts: Set<Int>) {
        self.holder = holder
        if holder.isCodexAppServer,
           holder.parentPID == 1,
           holder.isPrivateCmuxServer,
           !holder.hasConnectedClients,
           !holder.hasControllingTerminal,
           holder.pidVersion != nil,
           let port = holder.appServerPort,
           !watchedAppServerPorts.contains(port) {
            classification = .orphanedAppServer
        } else if holder.isCodexAppServer {
            classification = .ownedAppServer
        } else {
            classification = .other
        }
    }
}
