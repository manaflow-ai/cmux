import Foundation

/// One item in a `cmux.json` context menu: either an action entry or a
/// separator. Decodes both the bare-string shorthand (`"-"`/`"separator"` for a
/// separator, any other string for an action id) and the object form.
public enum CmuxConfigContextMenuItem: Codable, Sendable, Hashable {
    case action(CmuxConfigContextMenuActionItem)
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
