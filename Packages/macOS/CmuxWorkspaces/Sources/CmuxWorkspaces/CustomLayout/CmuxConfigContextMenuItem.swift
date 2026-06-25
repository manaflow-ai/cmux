import Foundation

/// One concrete action row in a `cmux.json` button `contextMenu` (a.k.a.
/// `rightClick`) array: the action id plus its optional presentation overrides.
///
/// This is the `Codable`, `Sendable` wire image of a context-menu action entry.
/// Its ``init(from:)`` requires a non-blank trimmed `action` id and treats
/// blank `title`/`tooltip` as absent (blank-as-nil), while ``CmuxButtonIcon``
/// decodes the optional `icon`. Changing any token here is a wire-format change
/// to every user's `cmux.json`. The AppKit rendering of ``CmuxButtonIcon`` into
/// an `NSImage` for the menu lives app-side as a separate extension.
public struct CmuxConfigContextMenuActionItem: Codable, Sendable, Hashable {
    /// The action id this menu row runs (required, trimmed, non-blank).
    public var action: String
    /// The display title override, or `nil` to use the action's own title.
    public var title: String?
    /// The icon override, or `nil` to use the action's own icon.
    public var icon: CmuxButtonIcon?
    /// The tooltip override, or `nil`.
    public var tooltip: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case title
        case icon
        case tooltip
    }

    /// Creates a context-menu action item with an explicit action id and
    /// optional presentation overrides.
    public init(action: String, title: String? = nil, icon: CmuxButtonIcon? = nil, tooltip: String? = nil) {
        self.action = action
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try Self.requiredTrimmedString(forKey: .action, in: container)
        title = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        icon = try container.decodeIfPresent(CmuxButtonIcon.self, forKey: .icon)
        tooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        guard let value = try trimmedString(forKey: key, in: container) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "\(key.stringValue) is required"
                )
            )
        }
        return value
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

/// One entry in a `cmux.json` button `contextMenu` (or `rightClick`) array:
/// either an action row or a separator.
///
/// This is the `Codable`, `Sendable` wire image of a context-menu entry. Its
/// ``init(from:)`` accepts two shapes: a bare string (decoded via a single-value
/// container) where `"-"` or `"separator"` becomes ``separator`` and any other
/// non-blank string becomes an ``action`` referencing it by id; or an object
/// with a `type` field of `"separator"` (else decoded as a
/// ``CmuxConfigContextMenuActionItem``). On encode an ``action`` re-encodes the
/// item inline and a ``separator`` writes `{"type":"separator"}`. Changing any
/// token here is a wire-format change to every user's `cmux.json`.
public enum CmuxConfigContextMenuItem: Codable, Sendable, Hashable {
    /// A concrete action row.
    case action(CmuxConfigContextMenuActionItem)
    /// A horizontal separator.
    case separator

    private enum CodingKeys: String, CodingKey {
        case type
        case action
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawAction = try? container.decode(String.self) {
            let trimmed = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "-" || trimmed == "separator" {
                self = .separator
                return
            }
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "contextMenu action must not be blank"
                    )
                )
            }
            self = .action(CmuxConfigContextMenuActionItem(action: trimmed))
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        if rawType == "separator" {
            self = .separator
            return
        }
        self = .action(try CmuxConfigContextMenuActionItem(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .action(let item):
            try item.encode(to: encoder)
        case .separator:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("separator", forKey: .type)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}
