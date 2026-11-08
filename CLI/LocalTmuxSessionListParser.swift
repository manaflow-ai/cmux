import Foundation

/// Parses bounded tmux list output without silently dropping malformed rows.
struct LocalTmuxSessionListParser {
    struct SessionLine {
        let name: String
        let binding: LocalTmuxSessionBinding
        let windows: Int

        var identity: LocalTmuxSessionIdentity { binding.sessionID }
        var created: String { String(binding.sessionCreated) }
    }

    struct ClientLine {
        let clientID: String
        let sessionName: String
        let pid: String
        let tty: String
    }

    func sessions(_ output: String) throws -> [SessionLine] {
        try output.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5,
                  !fields[0].isEmpty,
                  let sessionID = LocalTmuxSessionIdentity(fields[1]),
                  let serverID = UUID(uuidString: fields[2]),
                  let sessionCreated = UInt64(fields[3]),
                  let windows = Int(fields[4]) else {
                throw CLIError(message: String(
                    localized: "cli.localTmux.error.listingIncomplete",
                    defaultValue: "local-tmux session listing was incomplete; liveness is unknown."
                ))
            }
            return SessionLine(
                name: fields[0],
                binding: LocalTmuxSessionBinding(
                    sessionID: sessionID,
                    serverID: serverID,
                    sessionCreated: sessionCreated
                ),
                windows: windows
            )
        }
    }

    func clients(_ output: String) throws -> [ClientLine] {
        try output.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.localTmux.error.clientListFailed",
                    defaultValue: "local-tmux could not inspect attached clients."
                ))
            }
            return ClientLine(
                clientID: fields[0],
                sessionName: fields[1],
                pid: fields[2],
                tty: fields[3]
            )
        }
    }
}
