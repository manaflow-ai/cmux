public import CmuxNextDaemon
public import CmuxNextFloating

/// The Chief pet's notice from a daemon notification (`NotificationCenterService+ChiefPet` feeds it).
@MainActor
extension ChiefPetNotice {
    /// The notice says which chat and what happened: the program's or poster's title, else the tab's name
    /// (else the workspace's) with what happened ("New chat finished"; "finished" only for an agent's
    /// notice, as a shell's titleless line finished nothing); then the workspace and one line of its text
    /// (else the subtitle), as "workspace · text". A bare tab name over a bare step ("New chat" /
    /// "Ran command") said neither (Leo 2026-10-20). A terminal takes a typed reply only for an
    /// agent's notice or one whose poster asked for it (like a `notify --reply` banner); any other
    /// opens its tab (an OSC 9/777 line from a remote shell or a log must not type into what runs there).
    /// An agent chat opens.
    /// `name`: the tab's shown name (a Home conversation tab's is its Chief's own), else its record's.
    /// The rules are `welcome.petNotice` (cmux-home-rules), with the localized "finished", "needs your input"
    /// and "failed" titles passed in as formats.
    public init(_ notification: DaemonNotification, tab: TabModel, name: String? = nil, workspace: String?, programTitle: String?,
                body: String) {
        let input = NoticeInput(level: notification.level.rawValue, title: notification.title, subtitle: notification.shownSubtitle,
                                source: notification.source, reply: notification.reply, tabTitle: tab.displayTitle, tabIsPty: tab.kind == .pty,
                                tabHasAgentSession: tab.agentSession != nil, name: name, workspace: workspace, programTitle: programTitle, body: body,
                                finishedFormat: Self.title("%@", kind: .done), needsYouFormat: Self.title("%@", kind: .needsYou),
                                failedFormat: Self.title("%@", kind: .failed))
        let fallback = NoticeReply(title: notification.title, detail: "", kind: "done", reply: "openTab")
        let notice: NoticeReply = welcomeRule("welcome.petNotice", input, fallback: fallback)
        let kind: ChiefPetNotice.Kind = switch notice.kind {
        case "needsYou": .needsYou
        case "failed": .failed
        default: .done
        }
        let reply: ChiefPetNotice.Reply = switch notice.reply {
        case "type": .type
        case "openChat": .openChat
        default: .openTab
        }
        self.init(id: notification.notification.rawValue, tab: tab.id, surface: notification.surface?.rawValue,
                  title: notice.title, detail: notice.detail, kind: kind, reply: reply)
    }

    /// A terminal notice the pet may type an answer into: an agent's, or one posted with `--reply`.
    public static func takesTypedReply(_ notification: DaemonNotification) -> Bool {
        notification.reply || notification.source == "agent"
    }
}

// The pet notice op's wire shapes (cmux-home-rules `welcome/pet.rs`).
private nonisolated struct NoticeInput: Encodable {
    var level: String
    var title: String
    var subtitle: String?
    var source: String?
    var reply: Bool
    var tabTitle: String
    var tabIsPty: Bool
    var tabHasAgentSession: Bool
    var name: String?
    var workspace: String?
    var programTitle: String?
    var body: String
    var finishedFormat: String
    var needsYouFormat: String
    var failedFormat: String
}

private nonisolated struct NoticeReply: Decodable {
    var title: String
    var detail: String
    var kind: String
    var reply: String
}
