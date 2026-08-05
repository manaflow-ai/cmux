import CmuxFoundation
import Foundation

/// Finds the first existing filesystem candidate in one deadline-bounded subprocess.
///
/// A terminal path can point into an unresponsive filesystem. The child keeps
/// that filesystem call outside cmux, while `CommandRunner` terminates the
/// process at the deadline. Timeout, cancellation, malformed output, and launch
/// failure all fail closed.
struct WordPathFilesystemProbe: Sendable {
    private static let firstExistingPathScript = """
    realpath_executable=
    for executable_candidate in /bin/realpath /usr/bin/realpath; do
        if [ -x "$executable_candidate" ]; then
            realpath_executable=$executable_candidate
            break
        fi
    done
    [ -n "$realpath_executable" ] || exit 1

    index=0
    for candidate do
        if [ -e "$candidate" ]; then
            resolved_candidate=$("$realpath_executable" "$candidate") || exit 1
            kind=other
            if [ -f "$resolved_candidate" ] && [ -r "$resolved_candidate" ]; then
                kind=readable-file
            fi
            printf '%s\\0%s\\0%s\\n' "$index" "$kind" "$resolved_candidate"
            exit 0
        fi
        index=$((index + 1))
    done
    exit 1
    """

    private let commands: any CommandRunning
    private let timeout: TimeInterval

    init(
        commands: any CommandRunning = CommandRunner(),
        timeout: TimeInterval = 0.25
    ) {
        self.commands = commands
        self.timeout = timeout
    }

    func firstExistingPath(
        in paths: [String]
    ) async -> (
        index: Int,
        candidatePath: String,
        resolvedPath: String,
        isReadableRegularFile: Bool
    )? {
        guard !paths.isEmpty, !Task.isCancelled else { return nil }
        let result = await commands.run(
            directory: "/",
            executable: "/bin/sh",
            arguments: ["-c", Self.firstExistingPathScript, "cmux-path-probe"] + paths,
            timeout: timeout
        )
        guard !Task.isCancelled,
              result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let output = result.stdout,
              let indexSeparator = output.firstIndex(of: "\0"),
              let index = Int(output[..<indexSeparator]),
              paths.indices.contains(index)
        else {
            return nil
        }
        let kindStart = output.index(after: indexSeparator)
        guard let kindSeparator = output[kindStart...].firstIndex(of: "\0") else {
            return nil
        }
        let kind = output[kindStart..<kindSeparator]
        guard kind == "readable-file" || kind == "other" else { return nil }

        var resolvedPath = String(output[output.index(after: kindSeparator)...])
        if resolvedPath.last == "\n" {
            resolvedPath.removeLast()
        }
        guard resolvedPath.hasPrefix("/") else { return nil }
        return (index, paths[index], resolvedPath, kind == "readable-file")
    }
}
