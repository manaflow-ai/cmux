import Foundation

/// Fatal errors during `.cmux.yaml` parsing. Thrown for unrecoverable failures.
enum CmuxConfigError: Error, Equatable {
    case invalidYaml(details: String)
    case fileNotReadable(path: String)
}

/// Non-fatal warnings during `.cmux.yaml` parsing.
/// The config is still applied, but with the warned items degraded.
enum CmuxConfigWarning: Equatable {
    /// A referenced startup script was not found in the script repository.
    case scriptNotFound(name: String)
    /// A sub-group tried to nest groups beyond the 2-level limit.
    case maxDepthExceeded(groupName: String)
}

/// Result of parsing a `.cmux.yaml` file.
/// Contains the project definition plus any non-fatal warnings.
struct ConfigParseResult {
    let projectName: String
    let projectColor: String?
    let warnings: [CmuxConfigWarning]
    /// Tab definitions with their startup script names (to be resolved later).
    let tabDefinitions: [ConfigTabDefinition]
}

/// A tab definition from `.cmux.yaml`, not yet resolved to a workspace.
struct ConfigTabDefinition {
    let title: String
    let startupScript: String?
    let groupPath: [String]  // empty = top-level, ["sub"] = inside sub-group "sub"
}
