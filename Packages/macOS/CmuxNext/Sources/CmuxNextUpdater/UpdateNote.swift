import Foundation

/// The result of a check that leaves nothing to install: what the notice
/// card says after the user asked (``UpdateCard/note(_:)``).
nonisolated public enum UpdateNote: Equatable, Sendable {
    /// Nothing newer for this Mac.
    case upToDate
    /// The check failed (the update sheet has the details).
    case checkFailed
    /// A development build's read-only probe found `version`; such a build
    /// never installs updates.
    case found(version: String)
    /// A newer build `version` exists but needs macOS `required`.
    case needsNewerMacOS(version: String, required: String)

    public var isError: Bool { self == .checkFailed }

    /// The one-line text (tooltips, `updates.status`).
    public var text: String {
        switch self {
        case .upToDate: UpdaterStrings.upToDate
        case .checkFailed: UpdaterStrings.checkFailed
        case .found(let version): UpdaterStrings.available(version)
        case .needsNewerMacOS(_, let required): UpdaterStrings.needsNewerMacOS(required)
        }
    }
}
