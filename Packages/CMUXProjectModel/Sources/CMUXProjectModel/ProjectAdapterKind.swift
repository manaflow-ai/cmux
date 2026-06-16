import Foundation

/// Identifies which ecosystem adapter produced a ``ProjectModel``.
///
/// Each adapter populates the shared model from its native metadata source:
/// the Xcode adapter parses `.xcodeproj` and `.xcworkspace`; future adapters
/// shell out to `cargo metadata`, the Gradle Tooling API, `pnpm m ls --json`,
/// or fall back to a plain filesystem walk.
///
/// UI code that wants to render adapter-specific affordances (e.g. a Cargo
/// features toggle) discriminates on this value.
public enum ProjectAdapterKind: String, Sendable, Hashable, Codable {
    case xcode
    case cargo
    case gradle
    case node
    case filesystem
}
