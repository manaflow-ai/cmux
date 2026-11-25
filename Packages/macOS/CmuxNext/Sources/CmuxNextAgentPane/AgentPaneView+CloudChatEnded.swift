import Foundation

/// A Mac tab that showed a Cloud chat in place, whose Cloud chat went (its tab closed on the machine, the
/// machine deleted, the start's first turn failing there): the tab draws its own new page again, and that
/// page says so above the composer instead of opening blank (cmux#55066: "it just shows a blank screen
/// after not working"). The prompt the start took goes back into the composer (the app's seed); the notice
/// says where it went and the ways on, and Dismiss closes it.
extension AgentPaneView {
    /// Shows the notice; `machine` is the Cloud machine's name, when known.
    public func showCloudChatEnded(machine: String?, promptBack: Bool) {
        cloudChatEndedNotice = AgentPaneNotice(
            id: Self.cloudChatEndedID, title: Self.cloudChatEndedTitle(machine: machine),
            detail: Self.cloudChatEndedDetail(promptBack: promptBack), button: Self.cloudChatEndedDismiss
        ) { [weak self] _ in
            self?.cloudChatEndedNotice = nil
            self?.pushPaneNotices()
        }
        pushPaneNotices()
    }

    static let cloudChatEndedID = "cloudChatEnded"

    static func cloudChatEndedTitle(machine: String?) -> String {
        guard let machine, !machine.isEmpty else {
            return String(localized: "agentPane.cloudChatEnded.title",
                          defaultValue: "The Cloud chat ended before it could go on.", bundle: .localizedModule)
        }
        return String(format: String(localized: "agentPane.cloudChatEnded.titleOn",
                                     defaultValue: "The Cloud chat on %@ ended before it could go on.", bundle: .localizedModule), machine)
    }

    static func cloudChatEndedDetail(promptBack: Bool) -> String {
        promptBack
            ? String(localized: "agentPane.cloudChatEnded.promptBack",
                     defaultValue: "Its agent may be out of usage, or the machine stopped. Your message is back in the composer: send it again, or pick another agent or machine first.",
                     bundle: .localizedModule)
            : String(localized: "agentPane.cloudChatEnded.detail",
                     defaultValue: "Its agent may be out of usage, or the machine stopped. Send a message to start a new chat, or pick another agent or machine first.",
                     bundle: .localizedModule)
    }

    static var cloudChatEndedDismiss: String {
        String(localized: "agentPane.cloudChatEnded.dismiss", defaultValue: "Dismiss", bundle: .localizedModule)
    }
}
