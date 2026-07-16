import Foundation

/// Optional action overrides for the bundled Project Worktrees sidebar.
struct CmuxConfigProjectWorktreesDefinition: Codable, Sendable, Hashable {
    var createAction: String?
    var openAction: String?

    private enum CodingKeys: String, CodingKey {
        case createAction
        case openAction
    }

    init(createAction: String? = nil, openAction: String? = nil) {
        self.createAction = createAction
        self.openAction = openAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        createAction = try Self.actionID(forKey: .createAction, in: container)
        openAction = try Self.actionID(forKey: .openAction, in: container)
    }

    private static func actionID(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let value = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            let format = String(
                localized: "worktreeSidebar.config.actionID.blank",
                defaultValue: "%@ must not be blank"
            )
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: String(format: format, key.stringValue)
            )
        }
        return value
    }
}
