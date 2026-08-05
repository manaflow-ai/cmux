import CmuxFoundation
import Foundation

/// Finds the first existing candidate in one deadline-bounded subprocess.
///
/// A terminal path can point into an unresponsive filesystem. The child keeps
/// that filesystem call outside cmux, while `CommandRunner` terminates the
/// process at the deadline. Timeout, cancellation, malformed output, and launch
/// failure all fail closed.
struct WordPathFilesystemProbe: Sendable {
    private static let firstExistingPathScript = """
    index=0
    for candidate do
        if [ -e "$candidate" ]; then
            printf '%s\\n' "$index"
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

    func firstExistingPathIndex(in paths: [String]) async -> Int? {
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
              let firstLine = result.stdout?.split(whereSeparator: \.isNewline).first,
              let index = Int(firstLine),
              paths.indices.contains(index)
        else {
            return nil
        }
        return index
    }
}
