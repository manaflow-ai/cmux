import Foundation

/// Binds cmux registry records to tmux-owned session identities.
struct LocalTmuxSessionIdentityResolver {
    struct LiveSession: Sendable {
        let record: LocalTmuxSessionRecord
        let identity: LocalTmuxSessionIdentity
    }

    enum Resolution: Sendable {
        case live(LiveSession)
        case stopped
    }

    let registry: LocalTmuxSessionRegistry
    let builder: LocalTmuxCommandBuilder
    let runner: LocalTmuxProcessRunner

    func identity(named sessionName: String) throws -> LocalTmuxSessionIdentity {
        try readIdentity(
            arguments: builder.sessionIdentityArguments(sessionName: sessionName),
            sessionName: sessionName
        )
    }

    func bind(
        _ record: LocalTmuxSessionRecord,
        to identity: LocalTmuxSessionIdentity
    ) throws -> LiveSession {
        if let storedValue = record.tmuxSessionID {
            guard let storedIdentity = LocalTmuxSessionIdentity(storedValue) else {
                throw LocalTmuxRegistryError.invalidState(registry.sessionsURL.path)
            }
            guard storedIdentity == identity else {
                throw identityChangedError(sessionName: record.name)
            }
            return LiveSession(record: record, identity: identity)
        }

        var updated = record
        updated.tmuxSessionID = identity.rawValue
        updated.updatedAt = Date.now.timeIntervalSince1970
        try registry.upsert(updated)
        return LiveSession(record: updated, identity: identity)
    }

    /// Returns the managed record for one listed session. A same-name session
    /// with a different tmux identity is deliberately left unmanaged.
    func reconciledRecord(
        _ record: LocalTmuxSessionRecord,
        liveIdentity: LocalTmuxSessionIdentity
    ) throws -> LocalTmuxSessionRecord? {
        guard let storedValue = record.tmuxSessionID else {
            return try bind(record, to: liveIdentity).record
        }
        guard let storedIdentity = LocalTmuxSessionIdentity(storedValue) else {
            throw LocalTmuxRegistryError.invalidState(registry.sessionsURL.path)
        }
        return storedIdentity == liveIdentity ? record : nil
    }

    func resolve(_ record: LocalTmuxSessionRecord) throws -> Resolution {
        if let storedValue = record.tmuxSessionID {
            guard let storedIdentity = LocalTmuxSessionIdentity(storedValue) else {
                throw LocalTmuxRegistryError.invalidState(registry.sessionsURL.path)
            }
            if try hasSession(arguments: builder.hasSessionArguments(sessionID: storedIdentity), sessionName: record.name) {
                let liveIdentity = try readIdentity(
                    arguments: builder.sessionIdentityArguments(sessionID: storedIdentity),
                    sessionName: record.name
                )
                guard liveIdentity == storedIdentity else {
                    throw identityChangedError(sessionName: record.name)
                }
                return .live(LiveSession(record: record, identity: storedIdentity))
            }

            if try hasSession(arguments: builder.hasSessionArguments(record.name), sessionName: record.name) {
                let replacementIdentity = try identity(named: record.name)
                guard replacementIdentity == storedIdentity else {
                    throw identityChangedError(sessionName: record.name)
                }
                return .live(LiveSession(record: record, identity: storedIdentity))
            }
            return .stopped
        }

        guard try hasSession(arguments: builder.hasSessionArguments(record.name), sessionName: record.name) else {
            return .stopped
        }
        return .live(try bind(record, to: identity(named: record.name)))
    }

    func requireLive(_ record: LocalTmuxSessionRecord) throws -> LiveSession {
        switch try resolve(record) {
        case let .live(session):
            return session
        case .stopped:
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.localTmux.error.sessionNotRunning", defaultValue: "local-tmux session is no longer running: %@"),
                record.name
            ))
        }
    }

    private func hasSession(arguments: [String], sessionName: String) throws -> Bool {
        let result = try runner.run(arguments: arguments)
        guard !result.outputWasTruncated else {
            throw identityUnavailableError(sessionName: sessionName)
        }
        if result.succeeded { return true }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if detail.isEmpty
            || detail.contains("can't find session")
            || detail.contains("session not found")
            || detail.contains("no server running")
            || (detail.contains("error connecting")
                && (detail.contains("no such file or directory") || detail.contains("connection refused"))) {
            return false
        }
        throw identityUnavailableError(sessionName: sessionName)
    }

    private func readIdentity(
        arguments: [String],
        sessionName: String
    ) throws -> LocalTmuxSessionIdentity {
        let result = try runner.run(arguments: arguments)
        let rawIdentity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded,
              !result.outputWasTruncated,
              let identity = LocalTmuxSessionIdentity(rawIdentity) else {
            throw identityUnavailableError(sessionName: sessionName)
        }
        return identity
    }

    private func identityChangedError(sessionName: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.localTmux.error.sessionIdentityChanged", defaultValue: "local-tmux session identity changed; refusing to operate on replacement session: %@"),
            sessionName
        ))
    }

    private func identityUnavailableError(sessionName: String) -> CLIError {
        CLIError(message: String.localizedStringWithFormat(
            String(localized: "cli.localTmux.error.sessionIdentityUnavailable", defaultValue: "local-tmux could not verify the tmux session identity: %@"),
            sessionName
        ))
    }
}
