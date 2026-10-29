import Foundation

/// Installs a public key into the server's `~/.ssh/authorized_keys` using a
/// password once, then proves the key works (PRD D16, like `ssh-copy-id`).
///
/// The password is only held for the duration of the call and is never
/// persisted or logged.
public struct SSHKeyInstaller: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Key appended (or already present) and a key-only login succeeded.
        case installed
    }

    /// The remote directory holding `authorized_keys`, as a shell word that
    /// may reference `$HOME`.
    let sshDirectory: String

    /// Creates an installer targeting the login user's `~/.ssh`.
    public init() {
        self.init(sshDirectory: "$HOME/.ssh")
    }

    init(sshDirectory: String) {
        self.sshDirectory = sshDirectory
    }

    /// Shell command that reads the key from stdin (so the key text needs no
    /// quoting) and appends it unless an identical line already exists.
    var installCommand: String {
        let script = """
        umask 077; IFS= read -r key || exit 64; d="\(sshDirectory)"; f="$d/authorized_keys"; \
        mkdir -p "$d" && touch "$f" && chmod 700 "$d" && chmod 600 "$f" && \
        { grep -qxF "$key" "$f" || printf '%s\\n' "$key" >> "$f"; }
        """
        return "sh -c " + script.posixShellSingleQuoted
    }

    /// Appends `publicKeyLine` over an already-authenticated connection.
    func append(publicKeyLine: String, over connection: SSHConnection) async throws {
        let result = try await connection.exec(installCommand, stdin: Data((publicKeyLine + "\n").utf8))
        guard result.exitStatus == 0 else {
            throw SSHConnectionError.channelRequestRejected("authorized_keys install failed: \(result.stderrString)")
        }
    }

    /// Appends `publicKeyLine` over a one-time password login, then proves a
    /// key-only login with `keyCredential` succeeds.
    public func install(
        publicKeyLine: String,
        endpoint: SSHEndpoint,
        password: String,
        verifyWith keyCredential: SSHCredential,
        hostKeyVerifier: any SSHHostKeyVerifier,
        via jump: SSHConnection? = nil
    ) async throws -> Outcome {
        let passwordConnection = try await SSHConnection.connect(
            to: endpoint,
            credentials: [.password(password)],
            hostKeyVerifier: hostKeyVerifier,
            via: jump
        )
        do {
            try await append(publicKeyLine: publicKeyLine, over: passwordConnection)
        } catch {
            await passwordConnection.close()
            throw error
        }
        await passwordConnection.close()
        let keyConnection = try await SSHConnection.connect(
            to: endpoint,
            credentials: [keyCredential],
            hostKeyVerifier: hostKeyVerifier,
            via: jump
        )
        await keyConnection.close()
        return .installed
    }
}
