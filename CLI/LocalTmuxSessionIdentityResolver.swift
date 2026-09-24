import Foundation

/// Binds cmux registry records to one session in one tmux server incarnation.
struct LocalTmuxSessionIdentityResolver {
    struct ObservedSession: Sendable {
        let name: String
        let binding: LocalTmuxSessionBinding
    }

    struct LiveSession: Sendable {
        let record: LocalTmuxSessionRecord
        let binding: LocalTmuxSessionBinding

        var identity: LocalTmuxSessionIdentity { binding.sessionID }
    }

    enum Resolution: Sendable {
        case live(LiveSession)
        case stopped
    }

    let registry: LocalTmuxSessionRegistry
    let builder: LocalTmuxCommandBuilder
    let runner: LocalTmuxProcessRunner

    func ensureServerIdentity(sessionName: String = "server") throws {
        let result = try runner.run(
            arguments: builder.ensureServerIdentityArguments(candidate: UUID())
        )
        guard result.succeeded, !result.outputWasTruncated else {
            throw identityUnavailableError(sessionName: sessionName)
        }
    }

    func observedSession(named sessionName: String) throws -> ObservedSession {
        try ensureServerIdentity(sessionName: sessionName)
        return try readObservedSession(
            arguments: builder.sessionBindingArguments(sessionName: sessionName),
            sessionName: sessionName
        )
    }

    func observedSession(sessionID: LocalTmuxSessionIdentity, nameHint: String) throws -> ObservedSession {
        try ensureServerIdentity(sessionName: nameHint)
        return try readObservedSession(
            arguments: builder.sessionBindingArguments(sessionID: sessionID),
            sessionName: nameHint
        )
    }

    func bind(
        _ record: LocalTmuxSessionRecord,
        to observed: ObservedSession
    ) throws -> LiveSession {
        if let storedBinding = record.tmuxBinding,
           storedBinding != observed.binding {
            throw identityChangedError(sessionName: record.name)
        }

        var updated = record
        updated.name = observed.name
        updated.tmuxBinding = observed.binding
        if updated != record {
            updated.updatedAt = Date.now.timeIntervalSince1970
            try registry.upsert(updated)
        }
        return LiveSession(record: updated, binding: observed.binding)
    }

    /// Returns the managed record for a listed session. A same-name session
    /// from another server incarnation is deliberately left unmanaged.
    func reconciledRecord(
        _ record: LocalTmuxSessionRecord,
        observed: ObservedSession
    ) throws -> LocalTmuxSessionRecord? {
        if let storedBinding = record.tmuxBinding {
            guard storedBinding == observed.binding else { return nil }
        } else {
            guard record.name == observed.name else { return nil }
        }
        return try bind(record, to: observed).record
    }

    func resolve(_ record: LocalTmuxSessionRecord) throws -> Resolution {
        if let storedBinding = record.tmuxBinding {
            if try hasSession(
                arguments: builder.hasSessionArguments(sessionID: storedBinding.sessionID),
                sessionName: record.name
            ) {
                let observed = try observedSession(
                    sessionID: storedBinding.sessionID,
                    nameHint: record.name
                )
                guard observed.binding == storedBinding else {
                    throw identityChangedError(sessionName: record.name)
                }
                return .live(try bind(record, to: observed))
            }

            if try hasSession(arguments: builder.hasSessionArguments(record.name), sessionName: record.name) {
                let replacement = try observedSession(named: record.name)
                guard replacement.binding == storedBinding else {
                    throw identityChangedError(sessionName: record.name)
                }
                return .live(try bind(record, to: replacement))
            }
            return .stopped
        }

        guard try hasSession(arguments: builder.hasSessionArguments(record.name), sessionName: record.name) else {
            return .stopped
        }
        return .live(try bind(record, to: observedSession(named: record.name)))
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

    private func readObservedSession(
        arguments: [String],
        sessionName: String
    ) throws -> ObservedSession {
        let result = try runner.run(arguments: arguments)
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        guard result.succeeded,
              !result.outputWasTruncated,
              lines.count == 1 else {
            throw identityUnavailableError(sessionName: sessionName)
        }
        let fields = lines[0]
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 4,
              !fields[0].isEmpty,
              let sessionID = LocalTmuxSessionIdentity(fields[1]),
              let serverID = UUID(uuidString: fields[2]),
              let sessionCreated = UInt64(fields[3]) else {
            throw identityUnavailableError(sessionName: sessionName)
        }
        return ObservedSession(
            name: fields[0],
            binding: LocalTmuxSessionBinding(
                sessionID: sessionID,
                serverID: serverID,
                sessionCreated: sessionCreated
            )
        )
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
