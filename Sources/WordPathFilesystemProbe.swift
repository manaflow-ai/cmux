import CmuxFoundation
import Foundation

/// Finds the first readable regular-file candidate in one deadline-bounded subprocess.
///
/// A terminal path can point into an unresponsive filesystem. The child keeps
/// that filesystem call outside cmux, while `CommandRunner` terminates the
/// process at the deadline. Timeout, cancellation, malformed output, and launch
/// failure all fail closed.
struct WordPathFilesystemProbe: Sendable {
    private static let firstExistingPathScript = """
    index=0
    for candidate do
        if [ -f "$candidate" ] && [ -r "$candidate" ]; then
            printf '%s\\0' "$index"
            exec /bin/realpath "$candidate"
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
    ) async -> (index: Int, candidatePath: String, resolvedPath: String)? {
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
              let separator = output.firstIndex(of: "\0"),
              let index = Int(output[..<separator]),
              paths.indices.contains(index)
        else {
            return nil
        }
        var resolvedPath = String(output[output.index(after: separator)...])
        if resolvedPath.last == "\n" {
            resolvedPath.removeLast()
        }
        guard resolvedPath.hasPrefix("/") else { return nil }
        return (index, paths[index], resolvedPath)
    }
}
