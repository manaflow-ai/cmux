public import CmuxNextSettings
public import Foundation

/// One device chat as the New Tab page's cards show it: the acpmux chat index's metadata only
/// (the same source as the sidebar's All chats). Opening goes back to the host by `key`.
public nonisolated struct AgentPaneDeviceChat: Hashable, Sendable {
    /// `harness:sessionId`, the index key `_acpmux/chat_open` takes.
    public var key: String
    public var harness: String
    public var title: String?
    public var updatedAt: Date

    public init(key: String, harness: String, title: String?, updatedAt: Date) {
        self.key = key
        self.harness = harness
        self.title = title
        self.updatedAt = updatedAt
    }

    /// The most chats one push carries (the page shows a few cards).
    public static let maximumPushed = 24

    var json: JSONValue {
        var object: [String: JSONValue] = ["key": .string(key), "harness": .string(harness),
                                           "updatedAt": .number((updatedAt.timeIntervalSince1970 * 1000).rounded())]
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

extension AgentPageEvent {
    /// The newest device chats for the New Tab page (`deviceChats`).
    public static func deviceChats(_ chats: [AgentPaneDeviceChat]) -> AgentPageEvent {
        AgentPageEvent(kind: "deviceChats", value: .array(chats.prefix(AgentPaneDeviceChat.maximumPushed).map(\.json)))
    }
}

extension AgentPaneView {
    /// Pushes ``deviceChats`` to the page.
    func applyDeviceChats() {
        let event = AgentPageEvent.deviceChats(deviceChats)
        deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyDeviceChats?.(\(event.value.compactText));"])
    }
}
