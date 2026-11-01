public import Foundation

/// A capability probe and the minimal file operations needed to deliver a
/// short-lived access token. The app server remains the only transport; this
/// abstraction keeps the broker testable and lets the VM bridge own its probe.
nonisolated public struct CloudCodexBrokerTarget: Sendable {
    nonisolated public struct Capability: Sendable, Equatable {
        public let ownerVM: Bool
        public let protocolVersion: Int
        public let codexExternalAccessToken: Bool

        nonisolated public init(ownerVM: Bool, protocolVersion: Int, codexExternalAccessToken: Bool) {
            self.ownerVM = ownerVM
            self.protocolVersion = protocolVersion
            self.codexExternalAccessToken = codexExternalAccessToken
        }
    }

    public let machineID: String
    /// A non-waking machine status check. Renewal must not resume a paused VM.
    public let isLive: @Sendable () async throws -> Bool
    public let capability: @Sendable () async throws -> Capability
    public let makeDirectory: @Sendable (String) async throws -> Void
    public let readFile: @Sendable (String) async throws -> Data?
    public let writeFile: @Sendable (String, Data, Int) async throws -> Void
    public let commitFiles: @Sendable (String, String, String, String) async throws -> Void
    public let removeFile: @Sendable (String) async throws -> Void

    nonisolated public init(machineID: String,
                capability: @escaping @Sendable () async throws -> Capability,
                makeDirectory: @escaping @Sendable (String) async throws -> Void,
                readFile: @escaping @Sendable (String) async throws -> Data?,
                writeFile: @escaping @Sendable (String, Data, Int) async throws -> Void,
                commitFiles: @escaping @Sendable (String, String, String, String) async throws -> Void,
                removeFile: @escaping @Sendable (String) async throws -> Void,
                isLive: (@Sendable () async throws -> Bool)? = nil) {
        self.machineID = machineID
        self.isLive = isLive ?? { true }
        self.capability = capability
        self.makeDirectory = makeDirectory
        self.readFile = readFile
        self.writeFile = writeFile
        self.commitFiles = commitFiles
        self.removeFile = removeFile
    }

    private static let statusCommand = [
        "set -eu",
        #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
        #"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#,
        #"u=cmux; id -u "$u" >/dev/null 2>&1 || u=root"#,
        #"h=$(getent passwd "$u" | cut -d: -f6)"#,
        #"b="$h/.cmux/bin/cmux-tui""#,
        #"[ -x "$b" ] || { echo "cmux: this machine has no cmux-tui" >&2; exit 82; }"#,
        #"as_u env HOME="$h" "$b" acp --json status"#,
    ].joined(separator: "; ")

    static func supportsExternalAccess(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = object["capabilities"] as? [String] else { return false }
        return capabilities.contains("codex-external-access-v1")
    }

    /// Runs the fixed install transaction with privilege because the file API
    /// may stage root-owned files while exec runs as the work user. Token bytes
    /// travel only through the file API, never through this command.
    static func commitCommand(stageAccess: String, finalAccess: String, stageMode: String, finalMode: String) -> String {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = [
            "set -eu",
            "a=\(quote(stageAccess)); f=\(quote(finalAccess)); m=\(quote(stageMode)); n=\(quote(finalMode)); b=\(quote(stageMode + ".previous"))",
            #"for p in "$a" "$m"; do test -f "$p"; test ! -L "$p"; test "$(stat -c %a "$p")" = 600; case $(stat -c %u "$p") in 0|$(id -u cmux)) ;; *) exit 83 ;; esac; chown cmux:cmux "$p"; done"#,
            #"had_mode=0; if test -e "$n"; then test -f "$n"; test ! -L "$n"; cp -p -- "$n" "$b"; had_mode=1; fi"#,
            #"rollback() { if test "$had_mode" = 1; then mv -f -- "$b" "$n"; else rm -f -- "$n"; fi; }"#,
            #"trap rollback EXIT; mv -f -- "$m" "$n"; mv -f -- "$a" "$f"; trap - EXIT; rm -f -- "$b" || :"#,
        ].joined(separator: "; ")
        return "if [ \"$(id -u)\" = 0 ]; then /bin/sh -c \(quote(script)); else sudo -n /bin/sh -c \(quote(script)); fi"
    }

    /// The account API establishes ownership for this caller before the running
    /// bridge is queried for its token-delivery capability. `callerOwnsVM` and `isLive` default to
    /// the classic `/api/vm` attach answer and record; a Worker machine (the app server link) has
    /// no row there and passes its link's owner answer and its record's status instead.
    nonisolated public init(api: CloudAPIClient, machineID: String, scope: CloudCodexBrokerScope,
                            callerOwnsVM: (@Sendable () async throws -> Bool)? = nil,
                            isLive: (@Sendable () async throws -> Bool)? = nil) {
        let api = api.pinningTeam(scope.teamID)
        // Guest files are controlled by the VM and cannot authorize token delivery.
        let callerOwnsVM = callerOwnsVM ?? { try await api.attachEndpoint(machineID).vmKind == "owner" }
        self.init(machineID: machineID, capability: {
            guard try await callerOwnsVM() else {
                return Capability(ownerVM: false, protocolVersion: 0, codexExternalAccessToken: false)
            }
            let result = try await api.exec(machineID, command: Self.statusCommand, timeoutMs: 8_000)
            guard result.exitCode == 0, Self.supportsExternalAccess(result.stdout) else {
                return Capability(ownerVM: true, protocolVersion: 0, codexExternalAccessToken: false)
            }
            return Capability(ownerVM: true, protocolVersion: 1, codexExternalAccessToken: true)
        }, makeDirectory: { path in
            try await api.makeDirectory(machineID, path: path)
        }, readFile: { path in
            do { return try await api.readFile(machineID, path: path).data }
            catch let error as CloudAPIError {
                guard case .http(let status, let code, _, _, _) = error,
                      status == 404, code == "vm_file_not_found" else { throw error }
                return nil
            }
        }, writeFile: { path, data, mode in
            try await api.writeFile(machineID, path: path, data: data, mode: mode)
        }, commitFiles: { stageAccess, finalAccess, stageMode, finalMode in
            let command = Self.commitCommand(stageAccess: stageAccess, finalAccess: finalAccess,
                                             stageMode: stageMode, finalMode: finalMode)
            let result = try await api.exec(machineID, command: command, timeoutMs: 8_000)
            guard result.exitCode == 0 else { throw CloudCodexBrokerError.remoteDeliveryFailed }
        }, removeFile: { path in
            do { try await api.removeFile(machineID, path: path) }
            catch let error as CloudAPIError {
                guard case .http(let status, let code, _, _, _) = error,
                      status == 404, code == "vm_file_not_found" else { throw error }
            }
        }, isLive: isLive ?? {
            (try await api.machine(machineID)).status.isLive
        })
    }
}

