import CmuxFileSearch
import Foundation

/// Runs ripgrep on this Mac, streaming matches as they print.
struct LocalRipgrepFileSearchBackend: FileSearchBackend {
    func search(
        query: FileSearchQuery,
        rootPath: String,
        matchLimit: Int,
        sink: FileSearchBatchMailbox
    ) async -> FileSearchCompletion {
        let executable: FileSearchRipgrepExecutable
        switch RipgrepExecutableResolver.resolution() {
        case .found(let resolved):
            executable = resolved
        case .configuredPathNotExecutable(let path):
            return .failed(.unavailable(FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(path)))
        case .notFound:
            return .failed(.ripgrepNotFound)
        }
        let command = FileSearchCommand(
            executablePath: executable.url.path,
            arguments: executable.prefixArguments + RipgrepArguments.make(query: query, rootPath: rootPath)
        )
        return await RipgrepStreamingSearch.run(command: command, matchLimit: matchLimit, sink: sink)
    }
}

/// Runs ripgrep on an SSH host over the workspace's SSH connection settings,
/// streaming its JSON back through ssh's stdout.
///
/// The script travels on ssh's stdin to `sh -s`, so the remote login shell
/// (bash, zsh or fish) only has to start `sh`, and the pattern and paths reach
/// the host byte for byte instead of through a second layer of quoting.
struct SSHRipgrepFileSearchBackend: FileSearchBackend {
    let connection: SSHFileExplorerConnection

    /// Directories a non-interactive ssh session often lacks on PATH.
    static let fallbackRipgrepDirectories = [
        "$HOME/.cargo/bin",
        "$HOME/.local/bin",
        "$HOME/.nix-profile/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/run/current-system/sw/bin",
        "/usr/bin",
    ]

    func search(
        query: FileSearchQuery,
        rootPath: String,
        matchLimit: Int,
        sink: FileSearchBatchMailbox
    ) async -> FileSearchCompletion {
        let command = FileSearchCommand(
            executablePath: "/usr/bin/ssh",
            arguments: ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: "sh -s"),
            standardInput: Data(Self.remoteScript(ripgrepArguments: RipgrepArguments.make(query: query, rootPath: rootPath)).utf8)
        )
        let completion = await RipgrepStreamingSearch.run(command: command, matchLimit: matchLimit, sink: sink)
        // ssh itself exits 255 when it cannot connect or authenticate.
        if case .failed(.processFailed(let status, let message)) = completion, status == 255 {
            return .failed(.unavailable(FileExplorerSearchMessages.sshSearchFailed(message)))
        }
        return completion
    }

    /// A POSIX sh script that finds `rg` and replaces itself with it.
    static func remoteScript(
        ripgrepArguments: [String],
        fallbackDirectories: [String] = fallbackRipgrepDirectories
    ) -> String {
        let candidates = fallbackDirectories.map { "\"\($0)/rg\"" }.joined(separator: " ")
        let arguments = ripgrepArguments.map(shellSingleQuoted).joined(separator: " ")
        return """
        RG=rg
        if ! command -v rg >/dev/null 2>&1; then
          RG=
          for candidate in \(candidates.isEmpty ? "''" : candidates); do
            if [ -x "$candidate" ]; then RG=$candidate; break; fi
          done
        fi
        if [ -z "$RG" ]; then
          echo '\(RipgrepStreamingSearch.missingRipgrepMarker)' >&2
          exit 127
        fi
        exec "$RG" \(arguments) </dev/null

        """
    }

    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs ripgrep on a Cloud VM through the VM exec API. The API returns output
/// only when the command ends, so results arrive in one batch.
struct CloudFileSearchBackend: FileSearchBackend {
    let provider: CloudVMFileExplorerProvider

    func search(
        query: FileSearchQuery,
        rootPath: String,
        matchLimit: Int,
        sink: FileSearchBatchMailbox
    ) async -> FileSearchCompletion {
        do {
            let result = try await provider.search(query: query, rootPath: rootPath, matchLimit: matchLimit)
            sink.send(result.groups)
            return result.completion
        } catch is CancellationError {
            return .completed
        } catch {
            let message = (error as? FileExplorerError)?.localizedDescription
                ?? String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
            return .failed(.unavailable(message))
        }
    }
}
