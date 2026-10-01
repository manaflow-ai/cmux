import Foundation

/// The agent window's user-facing strings, localized from this module's table.
struct ConversationStrings {
    static var windowTitle: String { String(localized: "agent.window.title", defaultValue: "Agent Conversations", bundle: .module) }
    static var newConversation: String { String(localized: "agent.new", defaultValue: "New Conversation", bundle: .module) }
    static var send: String { String(localized: "agent.send", defaultValue: "Send", bundle: .module) }
    static var attach: String { String(localized: "agent.attach", defaultValue: "Attach Files…", bundle: .module) }
    static var placeholder: String { String(localized: "agent.composer.placeholder", defaultValue: "Message", bundle: .module) }
    static var sending: String { String(localized: "agent.delivery.sending", defaultValue: "Sending…", bundle: .module) }
    static func queued(_ position: Int) -> String {
        String(format: String(localized: "agent.delivery.queued", defaultValue: "Queued #%lld", bundle: .module), Int64(position))
    }
    static var uploading: String { String(localized: "agent.delivery.uploading", defaultValue: "Waiting for files", bundle: .module) }
    static var failed: String { String(localized: "agent.delivery.failed", defaultValue: "Not delivered. Click to retry.", bundle: .module) }
    static var steered: String { String(localized: "agent.delivery.steered", defaultValue: "Sent into the running turn", bundle: .module) }
    static var fileMissing: String { String(localized: "agent.file.missing", defaultValue: "Missing", bundle: .module) }
    static var deleted: String { String(localized: "agent.deleted", defaultValue: "This conversation was deleted.", bundle: .module) }
    static var cancelQueuedTitle: String { String(localized: "agent.dequeue.title", defaultValue: "Remove this queued message?", bundle: .module) }
    static var cancelQueuedBody: String { String(localized: "agent.dequeue.body", defaultValue: "It will not be sent to the agent.", bundle: .module) }
    static var remove: String { String(localized: "agent.dequeue.remove", defaultValue: "Remove", bundle: .module) }
    static var keep: String { String(localized: "agent.dequeue.keep", defaultValue: "Keep", bundle: .module) }
    static var largeFileTitle: String { String(localized: "agent.largefile.title", defaultValue: "Large attachment", bundle: .module) }
    static var largeFileBody: String { String(localized: "agent.largefile.body", defaultValue: "This file is large and may take a while to upload.", bundle: .module) }
    static var ok: String { String(localized: "agent.ok", defaultValue: "OK", bundle: .module) }
    static var stop: String { String(localized: "agent.stop", defaultValue: "Stop", bundle: .module) }
    static var unavailable: String { String(localized: "agent.unavailable", defaultValue: "The agent service is not running.", bundle: .module) }
}
