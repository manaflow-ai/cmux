import Foundation

/// Parses bounded tmux list output without silently dropping malformed rows.
struct LocalTmuxSessionListParser {
    struct SessionLine {
        let name: String
        let identity: LocalTmuxSessionIdentity
        let windows: Int
        let created: String
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
            guard fields.count == 4,
                  !fields[0].isEmpty,
                  let identity = LocalTmuxSessionIdentity(fields[1]),
                  let windows = Int(fields[2]) else {
                throw CLIError(message: String(
                    localized: "cli.localTmux.error.listingIncomplete",
                    defaultValue: "local-tmux session listing was incomplete; liveness is unknown."
                ))
            }
            return SessionLine(
                name: fields[0],
                identity: identity,
                windows: windows,
                created: fields[3]
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
