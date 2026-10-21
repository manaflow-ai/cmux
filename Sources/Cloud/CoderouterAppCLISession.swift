import CmuxAuthRuntime
import CmuxCloud
import Foundation
import OSLog

/// The cmux app's signed-in session, captured for one CodeRouter CLI command.
///
/// The tokens are never logged or persisted outside the private session
/// directory that ``CoderouterAppCLISession`` deletes after the command.
struct CoderouterAppCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let accountID: String
    let accessToken: String
    let refreshToken: String

    var description: String { "CoderouterAppCredentials(accountID: <redacted>, tokens: <redacted>)" }
    var debugDescription: String { description }
}

/// Supplies the session the sidebar's CodeRouter commands run as.
protocol CoderouterAppCredentialProviding: Sendable {
    /// Returns the app's current session. `expectedAccountID` is the signed-in
    /// account the caller's rows belong to; a different account is an error so
    /// a read can never run as whoever signed in after the request started.
    func credentials(expectedAccountID: String?) async throws -> CoderouterAppCredentials
}

/// The slice of the app's auth the sidebar needs. AuthCoordinator is the
/// production conformer; tests supply account and session transitions.
protocol CoderouterAppSessionAuth: Sendable {
    func authenticatedSessionSnapshot() async throws -> AuthenticatedSessionSnapshot
    func isAuthenticatedSessionCurrent(_ snapshot: AuthenticatedSessionSnapshot) async -> Bool
    func coherentTokenPair() async throws -> (accessToken: String, refreshToken: String)
}

extension AuthCoordinator: CoderouterAppSessionAuth {}

/// The production provider: the same native session the routed-agent handoff
/// (`CodeRouterHandoffClient`) sends to CodeRouter. The app resolves a fresh
/// access token itself, so a read never needs the CLI to refresh it; only an
/// Add Account flow that outlives the token refreshes inside its private copy.
struct CoderouterAppCredentialSource: CoderouterAppCredentialProviding {
    let auth: any CoderouterAppSessionAuth

    func credentials(expectedAccountID: String?) async throws -> CoderouterAppCredentials {
        do {
            let snapshot = try await auth.authenticatedSessionSnapshot()
            if let expectedAccountID, snapshot.accountID != expectedAccountID {
                throw CoderouterCLIFailure.unavailable
            }
            let tokens = try await auth.coherentTokenPair()
            // The pair must belong to the account captured above.
            guard await auth.isAuthenticatedSessionCurrent(snapshot) else {
                throw CoderouterCLIFailure.sessionChanging
            }
            return CoderouterAppCredentials(
                accountID: snapshot.accountID,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        } catch let failure as CoderouterCLIFailure {
            throw failure
        } catch is CancellationError {
            // A team or account switch restarts the read; that is not a failure.
            throw CancellationError()
        } catch AuthError.unauthorized {
            throw CoderouterCLIFailure.signInRequired
        } catch AuthError.offline, AuthError.networkError, AuthError.timedOut {
            throw CoderouterCLIFailure.unreachable
        } catch {
            throw CoderouterCLIFailure.unavailable
        }
    }
}

/// Where the CLI sends the app's session: the CodeRouter control plane and
/// the sign-in service the session belongs to.
struct CoderouterCLIEndpoints: Equatable, Sendable {
    let apiURL: String
    let stackAPIURL: String
    let stackProjectID: String

    /// The production control plane, or in a Debug build the tag's own
    /// backend when the CLI accepts it (HTTPS, or HTTP on loopback). The web
    /// app serves `/api/coderouter/*` on the same origin as the VM API.
    static var current: CoderouterCLIEndpoints {
        let stackBase = AuthEnvironment.stackBaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return CoderouterCLIEndpoints(
            apiURL: controlPlaneURL,
            stackAPIURL: stackBase + "/api/v1",
            stackProjectID: AuthEnvironment.stackProjectID
        )
    }

    private static var controlPlaneURL: String {
        let hosted = "https://coderouter.dev"
#if DEBUG
        let configured = AuthEnvironment.vmAPIBaseURL
        guard let host = configured.host?.lowercased() else { return hosted }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard configured.scheme == "https" || (configured.scheme == "http" && loopback) else { return hosted }
        return configured.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
#else
        return hosted
#endif
    }
}

/// Runs CodeRouter CLI commands as the cmux app's signed-in account.
///
/// Each command gets a private `CODEROUTER_DATA_DIR` whose `config.json`
/// holds the app's session and the selected team, so the sidebar never reads
/// or switches the user's own `cr login`. A terminal running `cr` keeps its
/// own sign-in untouched.
enum CoderouterAppCLISession {
    typealias Run = CoderouterCLIAccountReader.Run

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "coderouter-accounts")
    /// The CLI's sign-in check requires a route token. Account reads and writes
    /// use only the session above; the routed agent commands that would spend
    /// a route token never run from this configuration.
    static let routeTokenPlaceholder = "cmux-app-session"
    /// Where reads and removals keep their per-command configuration. They
    /// finish within a CLI timeout, so anything older was left by a crash.
    static let readSession = SessionKind(directoryName: "reads", staleAge: 10 * 60)
    /// Where New Account terminals keep theirs. The interactive sign-in can
    /// take a while; one older than a day was killed before its cleanup trap.
    static let addSession = SessionKind(directoryName: "adds", staleAge: 24 * 60 * 60)

    struct SessionKind: Sendable {
        let directoryName: String
        let staleAge: TimeInterval

        func root(in base: URL = CoderouterAppCLISession.baseDirectory) -> URL {
            base.appendingPathComponent(directoryName, isDirectory: true)
        }
    }

    static var baseDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-coderouter-sessions", isDirectory: true)
    }

    /// Removes configurations a crash or a killed terminal left behind. Runs
    /// at launch and before each new session.
    static func sweepAllStaleSessions(base: URL = baseDirectory, now: Date = Date()) {
        for kind in [readSession, addSession] {
            sweepStaleSessions(root: kind.root(in: base), olderThan: kind.staleAge, now: now)
        }
    }

    /// Runs `body` with a CLI runner bound to the app's session for `teamID`.
    /// The private configuration is removed when `body` returns or throws.
    static func withSession<T>(
        teamID: String,
        teamName: String?,
        expectedAccountID: String?,
        credentials provider: any CoderouterAppCredentialProviding,
        executable: String?,
        endpoints: CoderouterCLIEndpoints = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: URL = readSession.root(),
        body: (Run) async throws -> T
    ) async throws -> T {
        guard let executable else { throw CoderouterCLIFailure.notInstalled }
        let credentials = try await provider.credentials(expectedAccountID: expectedAccountID)
        try Task.checkCancellation()
        let directory = try makeSessionDirectory(
            credentials: credentials,
            teamID: teamID,
            teamName: teamName,
            endpoints: endpoints,
            root: root,
            staleAge: readSession.staleAge
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let commandEnvironment = isolatedEnvironment(environment, dataDirectory: directory)
        return try await body { arguments in
            do {
                return try await CoderouterCLIAccountReader.runProcess(
                    executable: executable,
                    arguments: arguments,
                    environment: commandEnvironment
                ).stdout
            } catch let error as NSError where error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain {
                // Process.run fails before the child starts, for example when
                // the resolved binary was removed after resolution.
                logger.error("Could not launch CodeRouter CLI: \(error.localizedDescription, privacy: .public)")
                throw CoderouterCLIFailure.notInstalled
            }
        }
    }

    /// The child's environment: no cmux context, no inherited CodeRouter
    /// overrides (an API key or team pin from the app's launch environment
    /// would replace the app session), and the private data directory.
    static func isolatedEnvironment(_ environment: [String: String], dataDirectory: URL) -> [String: String] {
        var result = environment.filter { key, _ in
            !key.hasPrefix("CMUX_") && !key.hasPrefix("CMUXD_") && !key.hasPrefix("CODEROUTER_")
        }
        result["CODEROUTER_DATA_DIR"] = dataDirectory.path
        return result
    }

    /// Creates a 0700 directory holding a 0600 `coderouter/config.json` for
    /// the app session. The caller owns its removal.
    static func makeSessionDirectory(
        credentials: CoderouterAppCredentials,
        teamID: String,
        teamName: String?,
        endpoints: CoderouterCLIEndpoints,
        root: URL,
        staleAge: TimeInterval,
        now: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // An existing root keeps its attributes; only a private one of ours is used.
        let rootAttributes = try fileManager.attributesOfItem(atPath: root.path)
        guard (rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CoderouterCLIFailure.unavailable
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        sweepStaleSessions(root: root, olderThan: staleAge, now: now)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let configDirectory = directory.appendingPathComponent("coderouter", isDirectory: true)
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let config = configuration(
                credentials: credentials,
                teamID: teamID,
                teamName: teamName,
                endpoints: endpoints
            )
            let body = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            guard fileManager.createFile(
                atPath: configDirectory.appendingPathComponent("config.json").path,
                contents: body,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CoderouterCLIFailure.unavailable
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// The CLI's config schema (coderouter 0.3.16 `Config`, camelCase). Every
    /// field is present because the CLI requires them all.
    static func configuration(
        credentials: CoderouterAppCredentials,
        teamID: String,
        teamName: String?,
        endpoints: CoderouterCLIEndpoints
    ) -> [String: String] {
        [
            "apiUrl": endpoints.apiURL,
            "stackApiUrl": endpoints.stackAPIURL,
            "stackProjectId": endpoints.stackProjectID,
            "stackAccessToken": credentials.accessToken,
            "stackRefreshToken": credentials.refreshToken,
            "teamId": teamID,
            "teamName": teamName ?? "",
            "routeToken": routeTokenPlaceholder,
            "routeTokenExpiresAt": "",
            "apiKey": "",
            "openaiBaseUrl": endpoints.apiURL + "/v1",
        ]
    }

    /// Removes session directories under `root` last modified before `staleAge`.
    static func sweepStaleSessions(root: URL, olderThan staleAge: TimeInterval, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > staleAge {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// The shell command a New Account terminal runs: the resolved CLI's
    /// interactive `add` for the team, as the app session, deleting the
    /// private configuration when the command exits or the terminal closes.
    static func addAccountCommand(
        provider: CoderouterProvider,
        organizationID: String,
        executable: String,
        sessionDirectory: URL
    ) -> String {
        let verb = provider.id == "opencode-go" ? "opencode" : provider.id
        let script = [
            "dir=\(shellQuote(sessionDirectory.path))",
            "trap 'rm -rf \"$dir\"' EXIT",
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
            // A login profile can export an API key or team pin that would
            // replace the app session inside the CLI.
            "unset CODEROUTER_API_KEY CODEROUTER_API_URL CODEROUTER_TEAM_ID CMUX_CODEROUTER_MACHINE",
            "CODEROUTER_DATA_DIR=\"$dir\" \(shellQuote(executable)) add \(verb) --team \(shellQuote(organizationID))",
        ].joined(separator: "; ")
        return "/bin/sh -c \(shellQuote(script))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
