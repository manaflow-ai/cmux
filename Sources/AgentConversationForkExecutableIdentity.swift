import Darwin
import Foundation

/// Stable identity of the probed harness executable. `stat` follows symlinks,
/// while `realPath` also binds discovery to the resolved install target.
struct AgentConversationForkExecutableIdentity: Equatable, Hashable, Sendable {
    let lookupPath: String
    let realPath: String
    let fingerprint: String
    let device: UInt64
    let shellStatSignature: String

    static func capture(
        executablePath: String,
        runtimeSearchPath: String?
    ) -> Self? {
        var environment: [String: String] = [:]
        if let runtimeSearchPath,
           !runtimeSearchPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["PATH"] = runtimeSearchPath
        }
        guard let identity = AgentForkSupport.forkProbeExecutableIdentity(
            executable: executablePath,
            processEnvironment: environment,
            workingDirectory: nil
        ) else {
            return nil
        }
        var status = stat()
        guard stat(identity.realPath, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        let device = UInt64(status.st_dev)
        let shellStatSignature = [
            String(device),
            String(status.st_ino),
            String(status.st_mode, radix: 8),
            String(status.st_size),
            String(status.st_mtimespec.tv_sec),
        ].joined(separator: ":")
        return Self(
            lookupPath: identity.lookupPath,
            realPath: identity.realPath,
            fingerprint: identity.cachePart,
            device: device,
            shellStatSignature: shellStatSignature
        )
    }
}

/// Creates the validated executable's hard link only inside the destination
/// terminal, immediately before launch. The random adjacent path preserves a
/// script launcher's relative resource directory while preventing later
/// replacement of its canonical pathname from changing the launched inode.
struct AgentConversationForkExecutableBinding: Equatable, Hashable, Sendable {
    let sourcePath: String
    let boundPath: String
    let expectedStatSignature: String

    init?(identity: AgentConversationForkExecutableIdentity) {
        let sourceURL = URL(fileURLWithPath: identity.realPath).standardizedFileURL
        let lookupURL = URL(fileURLWithPath: identity.lookupPath).standardizedFileURL
        let candidateDirectories = [
            sourceURL.deletingLastPathComponent(),
            lookupURL.deletingLastPathComponent(),
        ]
        var seenDirectories: Set<String> = []
        guard let directoryURL = candidateDirectories.first(where: { directoryURL in
            guard seenDirectories.insert(directoryURL.path).inserted else {
                return false
            }
            var status = stat()
            return stat(directoryURL.path, &status) == 0
                && status.st_mode & S_IFMT == S_IFDIR
                && UInt64(status.st_dev) == identity.device
                && Darwin.access(directoryURL.path, W_OK) == 0
        }) else {
            return nil
        }

        let basename = sourceURL.lastPathComponent
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "."
                    || scalar == "_"
                    || scalar == "-"
                    ? Character(String(scalar))
                    : "_"
            }
        let safeBasename = String(basename.prefix(80))
        let token = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let filename = ".cmux-transfer-\(token)-\(safeBasename.isEmpty ? "agent" : safeBasename)"

        sourcePath = sourceURL.path
        boundPath = directoryURL
            .appendingPathComponent(filename, isDirectory: false)
            .path
        expectedStatSignature = identity.shellStatSignature
    }

    func shellCommand(running launchCommand: String) -> String {
        let quotedSource = TerminalStartupShellQuoting.singleQuoted(sourcePath)
        let quotedBound = TerminalStartupShellQuoting.singleQuoted(boundPath)
        let quotedExpected = TerminalStartupShellQuoting.singleQuoted(
            expectedStatSignature
        )
        let quotedCleanup = TerminalStartupShellQuoting.singleQuoted(
            "/bin/rm -f -- \(quotedBound)"
        )
        return """
        cmux_transfer_source=\(quotedSource)
        cmux_transfer_bound=\(quotedBound)
        if ! /bin/ln -- "$cmux_transfer_source" "$cmux_transfer_bound"; then
          exit 76
        fi
        cmux_transfer_actual=$(/usr/bin/stat -f '%d:%i:%p:%z:%m' -- "$cmux_transfer_bound") || {
          /bin/rm -f -- "$cmux_transfer_bound"
          exit 76
        }
        if [[ "$cmux_transfer_actual" != \(quotedExpected) ]]; then
          /bin/rm -f -- "$cmux_transfer_bound"
          exit 76
        fi
        trap \(quotedCleanup) EXIT
        \(launchCommand)
        cmux_transfer_status=$?
        exit $cmux_transfer_status
        """
    }
}
