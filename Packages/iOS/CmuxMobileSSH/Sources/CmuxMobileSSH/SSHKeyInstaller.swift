import Foundation

/// Installs a public key into the server's `~/.ssh/authorized_keys` using a
/// password once, then proves the key works (PRD D16, like `ssh-copy-id`).
///
/// The password is only held for the duration of the call and is never
/// persisted or logged.
public enum SSHKeyInstaller {
    public enum Outcome: Sendable, Equatable {
        /// Key appended (or already present) and a key-only login succeeded.
        case installed
    }

    /// Shell command that reads the key from stdin (so the key text needs no
    /// quoting) and appends it unless an identical line already exists.
    static func installCommand(sshDirectory: String = "$HOME/.ssh") -> String {
        let script = """
        umask 077; IFS= read -r key || exit 64; d="\(sshDirectory)"; f="$d/authorized_keys"; \
        mkdir -p "$d" && touch "$f" && chmod 700 "$d" && chmod 600 "$f" && \
        { grep -qxF "$key" "$f" || printf '%s\\n' "$key" >> "$f"; }
        """
        return "sh -c " + shellQuote(script)
    }

    /// POSIX single-quote escaping.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Appends `publicKeyLine` over an already-authenticated connection.
    static func append(publicKeyLine: String, over connection: SSHConnection, sshDirectory: String = "$HOME/.ssh") async throws {
        let result = try await connection.exec(installCommand(sshDirectory: sshDirectory), stdin: Data((publicKeyLine + "\n").utf8))
        guard result.exitStatus == 0 else {
            throw SSHConnectionError.channelRequestRejected("authorized_keys install failed: \(result.stderrString)")
        }
    }

    public static func install(
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
