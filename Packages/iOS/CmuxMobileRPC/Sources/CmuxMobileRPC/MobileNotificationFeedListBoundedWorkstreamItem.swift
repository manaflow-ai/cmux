import Foundation

struct MobileNotificationFeedListBoundedWorkstreamItem: Decodable {
    private static let maximumQuestionCount = 16
    private static let maximumOptionCount = 32

    let item: MobileNotificationFeedWorkstreamItem?

    private enum CodingKeys: String, CodingKey {
        case id
        case workstreamID = "workstream_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case source
        case kind
        case createdAt = "created_at"
        case requestID = "request_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case plan
        case defaultMode = "default_mode"
        case questions
    }

    nonisolated init(from decoder: any Decoder) throws {
        let limits = try mobileNotificationFeedListBoundedDecodeOptions(from: decoder).stringLimits
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try container.boundedIdentity(.id, limit: limits.identifierByteLimit),
              let workstreamID = try container.boundedIdentity(
                  .workstreamID,
                  limit: limits.identifierByteLimit
              ),
              let requestID = try container.boundedIdentity(
                  .requestID,
                  limit: limits.identifierByteLimit
              ) else {
            item = nil
            return
        }
        let rawDate = try container.decode(String.self, forKey: .createdAt)
        guard let createdAt = try? Date(rawDate, strategy: .iso8601) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "Expected an ISO-8601 date"
            )
        }
        var questions: [MobileNotificationFeedQuestion] = []
        if var questionContainer = try container.nestedUnkeyedContainerIfPresent(forKey: .questions) {
            questions.reserveCapacity(min(
                Self.maximumQuestionCount,
                questionContainer.count ?? Self.maximumQuestionCount
            ))
            while !questionContainer.isAtEnd, questions.count < Self.maximumQuestionCount {
                try Task.checkCancellation()
                if let question = try questionContainer.decode(
                    BoundedQuestion.self,
                    limits: limits,
                    maximumOptionCount: Self.maximumOptionCount
                ) {
                    questions.append(question)
                }
            }
        }
        item = MobileNotificationFeedWorkstreamItem(
            id: id,
            workstreamID: workstreamID,
            workspaceID: try container.boundedOptionalIdentity(
                .workspaceID,
                limit: limits.identifierByteLimit
            ),
            surfaceID: try container.boundedOptionalIdentity(
                .surfaceID,
                limit: limits.identifierByteLimit
            ),
            source: try container.boundedString(.source, limit: limits.metadataByteLimit),
            kind: try container.boundedString(.kind, limit: limits.metadataByteLimit),
            createdAt: createdAt,
            requestID: requestID,
            toolName: try container.boundedOptionalString(.toolName, limit: limits.metadataByteLimit),
            toolInput: try container.boundedOptionalString(.toolInput, limit: limits.bodyByteLimit),
            plan: try container.boundedOptionalString(.plan, limit: limits.bodyByteLimit),
            defaultMode: try container.boundedOptionalString(
                .defaultMode,
                limit: limits.metadataByteLimit
            ),
            questions: questions
        )
    }
}

private extension MobileNotificationFeedListBoundedWorkstreamItem {
    struct BoundedQuestion {
        enum CodingKeys: String, CodingKey {
            case id, header, prompt, options
            case multiSelect = "multi_select"
        }

        static nonisolated func decode(
            from decoder: any Decoder,
            limits: MobileNotificationFeedListStringLimits,
            maximumOptionCount: Int
        ) throws -> MobileNotificationFeedQuestion? {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = try container.boundedIdentity(.id, limit: limits.identifierByteLimit) else {
                return nil
            }
            var options: [MobileNotificationFeedQuestionOption] = []
            if var optionContainer = try container.nestedUnkeyedContainerIfPresent(forKey: .options) {
                options.reserveCapacity(min(maximumOptionCount, optionContainer.count ?? maximumOptionCount))
                while !optionContainer.isAtEnd, options.count < maximumOptionCount {
                    try Task.checkCancellation()
                    if let option = try optionContainer.decode(BoundedOption.self, limits: limits) {
                        options.append(option)
                    }
                }
            }
            return MobileNotificationFeedQuestion(
                id: id,
                header: try container.boundedOptionalString(.header, limit: limits.metadataByteLimit),
                prompt: try container.boundedString(.prompt, limit: limits.bodyByteLimit),
                multiSelect: try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false,
                options: options
            )
        }
    }

    struct BoundedOption {
        enum CodingKeys: String, CodingKey {
            case id, label, description
        }

        static nonisolated func decode(
            from decoder: any Decoder,
            limits: MobileNotificationFeedListStringLimits
        ) throws -> MobileNotificationFeedQuestionOption? {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = try container.boundedIdentity(.id, limit: limits.identifierByteLimit) else {
                return nil
            }
            return MobileNotificationFeedQuestionOption(
                id: id,
                label: try container.boundedString(.label, limit: limits.metadataByteLimit),
                description: try container.boundedOptionalString(
                    .description,
                    limit: limits.metadataByteLimit
                )
            )
        }
    }
}

private extension UnkeyedDecodingContainer {
    mutating func decode(
        _: MobileNotificationFeedListBoundedWorkstreamItem.BoundedQuestion.Type,
        limits: MobileNotificationFeedListStringLimits,
        maximumOptionCount: Int
    ) throws -> MobileNotificationFeedQuestion? {
        let decoder = try superDecoder()
        return try MobileNotificationFeedListBoundedWorkstreamItem.BoundedQuestion.decode(
            from: decoder,
            limits: limits,
            maximumOptionCount: maximumOptionCount
        )
    }

    mutating func decode(
        _: MobileNotificationFeedListBoundedWorkstreamItem.BoundedOption.Type,
        limits: MobileNotificationFeedListStringLimits
    ) throws -> MobileNotificationFeedQuestionOption? {
        let decoder = try superDecoder()
        return try MobileNotificationFeedListBoundedWorkstreamItem.BoundedOption.decode(
            from: decoder,
            limits: limits
        )
    }
}

private extension KeyedDecodingContainer {
    func boundedIdentity(_ key: Key, limit: Int) throws -> String? {
        let value = try decode(String.self, forKey: key)
        return value.utf8.count <= limit ? value : nil
    }

    func boundedOptionalIdentity(_ key: Key, limit: Int) throws -> String? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return value.utf8.count <= limit ? value : nil
    }

    func boundedString(_ key: Key, limit: Int) throws -> String {
        try decode(String.self, forKey: key).boundedFeedPrefix(maximumUTF8Bytes: limit)
    }

    func boundedOptionalString(_ key: Key, limit: Int) throws -> String? {
        try decodeIfPresent(String.self, forKey: key)?.boundedFeedPrefix(maximumUTF8Bytes: limit)
    }

    func nestedUnkeyedContainerIfPresent(forKey key: Key) throws -> (any UnkeyedDecodingContainer)? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try nestedUnkeyedContainer(forKey: key)
    }
}

private extension String {
    func boundedFeedPrefix(maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes >= 0, utf8.count > maximumUTF8Bytes else { return self }
        var byteCount = 0
        var end = startIndex
        while end < endIndex {
            let next = index(after: end)
            let characterByteCount = self[end..<next].utf8.count
            guard byteCount + characterByteCount <= maximumUTF8Bytes else { break }
            byteCount += characterByteCount
            end = next
        }
        return String(self[..<end])
    }
}
