import Foundation

/// The phone agent GUI's strings.
struct AgentStrings {
    static var title: String { String(localized: "agent.title", defaultValue: "Agents", bundle: .module) }
    static var new: String { String(localized: "agent.new", defaultValue: "New Conversation", bundle: .module) }
    static var message: String { String(localized: "agent.message", defaultValue: "Message", bundle: .module) }
    static var send: String { String(localized: "agent.send", defaultValue: "Send", bundle: .module) }
    static var photos: String { String(localized: "agent.photos", defaultValue: "Photos", bundle: .module) }
    static var files: String { String(localized: "agent.files", defaultValue: "Files", bundle: .module) }
    static var sending: String { String(localized: "agent.sending", defaultValue: "Sending…", bundle: .module) }
    static func queued(_ n: Int) -> String { String(format: String(localized: "agent.queued", defaultValue: "Queued #%lld", bundle: .module), Int64(n)) }
    static var waitingFiles: String { String(localized: "agent.waitingFiles", defaultValue: "Waiting for files", bundle: .module) }
    static var failed: String { String(localized: "agent.failed", defaultValue: "Not delivered. Tap to retry.", bundle: .module) }
    static var missing: String { String(localized: "agent.missing", defaultValue: "Missing", bundle: .module) }
    static var deleted: String { String(localized: "agent.deleted", defaultValue: "This conversation was deleted.", bundle: .module) }
    static var removeTitle: String { String(localized: "agent.remove.title", defaultValue: "Remove this queued message?", bundle: .module) }
    static var removeBody: String { String(localized: "agent.remove.body", defaultValue: "It will not be sent to the agent.", bundle: .module) }
    static var remove: String { String(localized: "agent.remove", defaultValue: "Remove", bundle: .module) }
    static var keep: String { String(localized: "agent.keep", defaultValue: "Keep", bundle: .module) }
    static var largeTitle: String { String(localized: "agent.large.title", defaultValue: "Large attachment", bundle: .module) }
    static var largeBody: String { String(localized: "agent.large.body", defaultValue: "This file is large and may take a while to upload.", bundle: .module) }
    static var ok: String { String(localized: "agent.ok", defaultValue: "OK", bundle: .module) }
    static var stop: String { String(localized: "agent.stop", defaultValue: "Stop", bundle: .module) }
    static var offline: String { String(localized: "agent.offline", defaultValue: "Connecting to the Mac…", bundle: .module) }
    static var updateMac: String { String(localized: "agent.updateMac", defaultValue: "Update cmux on your Mac to use agent conversations.", bundle: .module) }
}
