public import Foundation

/// Identifies who produced a workspace title for recovery ordering.
public enum WorkspaceCustomizationTitleSource: String, Codable, Equatable, Sendable {
    case user
    case auto
}

/// One automatic title mutation handed off from a workspace owner at teardown.
///
/// The title is optional because an automatic clear must be durable too. This
/// value is `Sendable` so a nonisolated owner deinitializer can hand it to the
/// store's synchronous persistence boundary without retaining the owner.
public struct WorkspaceCustomizationPendingAutomaticTitle: Sendable, Equatable {
    public let stableId: UUID
    public let title: String?

    public init(stableId: UUID, title: String?) {
        self.stableId = stableId
        self.title = title
    }
}

/// One independently persisted workspace customization field.
///
/// `absent` means the recovery journal has never observed a mutation for the
/// field, while `cleared` is an explicit tombstone that prevents a stale
/// session snapshot from resurrecting an older value.
public enum WorkspaceCustomizationField: Codable, Equatable, Sendable {
    /// The field has no recovery-journal entry, so the session snapshot wins.
    case absent
    /// The most recent user mutation assigned the associated value.
    case value(String)
    /// The most recent automatic title mutation assigned the associated value.
    ///
    /// Automatic values are journaled so a clear followed by auto-naming has a
    /// durable ordering relative to a stale session snapshot.
    case autoValue(String)
    /// The most recent title mutation explicitly cleared the field.
    case cleared
}

/// Workspace identity persisted independently of session autosave.
///
/// Records are keyed by `Workspace.stableId`. Title and color are independent
/// so mutating one field never makes the other field authoritative.
public struct WorkspaceCustomization: Codable, Equatable, Sendable {
    /// Recovery state for the user-owned workspace title.
    public let customTitle: WorkspaceCustomizationField

    /// Recovery state for the user-owned workspace accent color.
    public let customColor: WorkspaceCustomizationField

    /// Creates a workspace customization recovery record.
    ///
    /// - Parameters:
    ///   - customTitle: Recovery state for the workspace title.
    ///   - customColor: Recovery state for the workspace accent color.
    public init(
        customTitle: WorkspaceCustomizationField = .absent,
        customColor: WorkspaceCustomizationField = .absent
    ) {
        self.customTitle = customTitle
        self.customColor = customColor
    }

    private enum CodingKeys: String, CodingKey {
        case customTitle
        case customColor
        // This key is intentionally additive. Older cmux versions ignore
        // unknown keyed values and continue to decode `customTitle` as `.value`.
        case customTitleSource
    }

    /// Decodes both the original field-only format and the provenance-aware
    /// format. Automatic titles are represented as `.value` plus an additive
    /// source key on disk so older binaries do not reject the whole journal.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedTitle = try container.decode(
            WorkspaceCustomizationField.self,
            forKey: .customTitle
        )
        let decodedSource = try container.decodeIfPresent(
            WorkspaceCustomizationTitleSource.self,
            forKey: .customTitleSource
        )
        if decodedSource == .some(.auto),
           case let .value(title) = decodedTitle {
            self.customTitle = .autoValue(title)
        } else {
            self.customTitle = decodedTitle
        }
        self.customColor = try container.decode(
            WorkspaceCustomizationField.self,
            forKey: .customColor
        )
    }

    /// Encodes automatic title provenance as an additive key while retaining
    /// the old `.value` wire shape for downgrade compatibility.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch customTitle {
        case let .autoValue(title):
            try container.encode(
                WorkspaceCustomizationField.value(title),
                forKey: .customTitle
            )
            try container.encode(
                WorkspaceCustomizationTitleSource.auto,
                forKey: .customTitleSource
            )
        default:
            try container.encode(customTitle, forKey: .customTitle)
        }
        switch customColor {
        case .autoValue:
            // Automatic provenance is meaningful only for titles. Do not
            // emit a new enum case in the color field that old decoders reject.
            try container.encode(
                WorkspaceCustomizationField.absent,
                forKey: .customColor
            )
        default:
            try container.encode(customColor, forKey: .customColor)
        }
    }
}
