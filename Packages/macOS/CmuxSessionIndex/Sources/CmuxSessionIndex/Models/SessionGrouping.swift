public import Foundation

/// How the session index groups its rows: by working directory or by agent.
///
/// The localized button `label` is NOT defined here. It binds `String(localized:)`
/// against the app bundle, which owns the `sessionIndex.group.*` keys, so the app
/// declares `label` as an extension on this type. The pure structure (raw value,
/// identity, SF Symbol name) lives in the package.
public enum SessionGrouping: String, CaseIterable, Identifiable, Codable, Sendable {
    case directory
    case agent

    public var id: String { rawValue }

    /// SF Symbol name for the grouping's toolbar button.
    public var symbolName: String {
        switch self {
        case .directory: return "folder"
        case .agent: return "person.2"
        }
    }
}
