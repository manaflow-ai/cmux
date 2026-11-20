import Foundation

/// New Message over the conversation simulator: `searchContacts`,
/// `lookupHandles` and `createConversation` on this backend's socket (see
/// services/conversation-sim/PROTOCOL.md).
extension ConversationSimBackend: ConversationDirectory {
    public func searchContacts(_ query: String, limit: Int, excluding: [String]) async throws -> [ConversationContact] {
        let params: [String: Any] = ["query": query, "limit": limit, "excludeIds": excluding]
        let result = try await core.request("searchContacts", params: JSONBox(params), timeout: .seconds(10)).value
        return (result["contacts"] as? [[String: Any]] ?? []).compactMap(WireDecoding.contact)
    }

    public func lookupHandles(_ handles: [String]) async throws -> [ConversationHandleLookup] {
        let result = try await core.request("lookupHandles", params: JSONBox(["handles": handles]), timeout: .seconds(15)).value
        return (result["results"] as? [[String: Any]] ?? []).map { raw in
            ConversationHandleLookup(
                handle: raw["handle"] as? String ?? "",
                service: (raw["service"] as? String).flatMap(ConversationService.init(rawValue:)),
                contact: (raw["contact"] as? [String: Any]).flatMap(WireDecoding.contact)
            )
        }
    }

    public func createConversation(_ recipients: [ConversationRecipientRef]) async throws -> ConversationCreation {
        let wire: [[String: Any]] = recipients.map { ref in
            switch ref {
            case let .participant(id): ["participantId": id]
            case let .handle(handle): ["handle": handle]
            }
        }
        let result = try await core.request("createConversation", params: JSONBox(["recipients": wire]), timeout: .seconds(15)).value
        guard let raw = result["conversation"] as? [String: Any], let info = WireDecoding.conversation(raw) else {
            throw ConversationBackendError(code: -4, message: "bad conversation")
        }
        return ConversationCreation(
            info: info,
            created: result["created"] as? Bool ?? false,
            service: (raw["service"] as? String).flatMap(ConversationService.init(rawValue:)) ?? .iMessage
        )
    }

    /// The WebSocket URL of another conversation on the same simulator.
    public func endpoint(forConversation id: String) -> URL {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { $0.name != "conversation" }
        items.insert(URLQueryItem(name: "conversation", value: id), at: 0)
        components.queryItems = items
        return components.url!
    }

    private var endpointURL: URL { core.endpoint }
}

extension WireDecoding {
    static func contact(_ raw: [String: Any]) -> ConversationContact? {
        guard let id = raw["id"] as? String else { return nil }
        let handles = (raw["handles"] as? [[String: Any]] ?? []).compactMap { h -> ConversationContactHandle? in
            guard let value = h["value"] as? String else { return nil }
            return ConversationContactHandle(
                value: value,
                label: h["label"] as? String ?? "",
                service: (h["service"] as? String).flatMap(ConversationService.init(rawValue:)) ?? .iMessage
            )
        }
        return ConversationContact(
            id: id,
            name: raw["name"] as? String ?? id,
            initials: raw["initials"] as? String ?? "",
            colorHex: raw["colorHex"] as? String ?? "#8E8E93",
            handles: handles
        )
    }
}
