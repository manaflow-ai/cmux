import Foundation

/// Where a newly-created workspace lands inside its group when the user
/// clicks the group header's + button (or invokes
/// `workspace.group.new_workspace`).
///   - ``afterCurrent`` — immediately after the current in-group workspace,
///     falling back to ``top`` when no in-group reference is supplied.
///   - ``top`` — second slot, immediately after the anchor.
///   - ``end`` — last slot, after the existing trailing member.
public enum WorkspaceGroupNewPlacement: String, CaseIterable, Sendable, Identifiable, SettingCodable {
    case afterCurrent
    case top
    case end

    public var id: String { rawValue }

    /// Tolerant parse used by every configuration surface (`cmux.json`,
    /// `settings.json`, the control socket): trims whitespace and accepts
    /// `aftercurrent` / `after-current` / `after_current` spellings
    /// case-insensitively.
    public init?(rawString: String?) {
        guard let raw = rawString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "aftercurrent", "after-current", "after_current":
            self = .afterCurrent
        case "top":
            self = .top
        case "end":
            self = .end
        default:
            return nil
        }
    }

    /// Decodes with the same tolerant parse the legacy
    /// `WorkspaceGroupNewWorkspacePlacementSettings.resolved` applied to the
    /// stored string, so previously stored variant spellings keep resolving.
    public static func decodeFromUserDefaults(_ raw: Any?) -> WorkspaceGroupNewPlacement? {
        guard let string = raw as? String else { return nil }
        return WorkspaceGroupNewPlacement(rawString: string)
    }

    public func encodeForUserDefaults() -> Any { rawValue }

    /// JSON config values get the same tolerant parse (`cmux.json` accepted
    /// the variant spellings through `init(rawString:)` before extraction).
    public static func decodeFromJSON(_ raw: Any?) -> WorkspaceGroupNewPlacement? {
        guard let string = raw as? String else { return nil }
        return WorkspaceGroupNewPlacement(rawString: string)
    }

    public func encodeForJSON() -> Any { rawValue }
}
