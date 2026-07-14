import Foundation

/// Builds child-process arguments that isolate Git from ambient repository state.
struct WorktreeSidebarGitEnvironment: Sendable {
    private let removedVariables = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_OPTIONAL_LOCKS",
        "GIT_PREFIX",
        "GIT_QUARANTINE_PATH",
        "GIT_WORK_TREE",
    ]

    func launchArguments(
        executable: String,
        arguments: [String],
        optionalLocks: Bool
    ) -> [String] {
        var result = removedVariables.flatMap { ["-u", $0] }
        if optionalLocks {
            result.append("GIT_OPTIONAL_LOCKS=0")
        }
        result.append(executable)
        result.append(contentsOf: arguments)
        return result
    }
}
