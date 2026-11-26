import Darwin
import Foundation

struct SudoRunnerParentValidator: Sendable {
    private let inspector: any SudoProcessInspecting
    private let parentProcessIdentifier: @Sendable () -> Int32

    init(
        inspector: any SudoProcessInspecting,
        parentProcessIdentifier: @Sendable @escaping () -> Int32 = { getppid() }
    ) {
        self.inspector = inspector
        self.parentProcessIdentifier = parentProcessIdentifier
    }

    /// Validates that the hidden runner was spawned directly by its enclosing cmux app.
    func validate(expectedExecutableURL: URL) -> Bool {
        let parent = parentProcessIdentifier()
        guard parent > 1,
              let identityBefore = inspector.identity(for: parent),
              let executableURL = inspector.executableURL(for: parent),
              let identityAfter = inspector.identity(for: parent),
              identityBefore == identityAfter else {
            return false
        }
        return executableURL.resolvingSymlinksInPath().standardizedFileURL
            == expectedExecutableURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
