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
    public init(_ notification: DaemonNotification, tab: TabModel, name: String? = nil, workspace: String?, programTitle: String?,
                body: String) {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let kind: ChiefPetNotice.Kind = switch notification.level {
        case .warning: .needsYou
        case .error: .failed
        case .info: .done
        }
        let text = line.isEmpty ? (notification.shownSubtitle ?? "") : line
        let shown = name ?? tab.displayTitle
        let name = shown.isEmpty ? (workspace ?? "") : shown
        let happened = name.isEmpty || (kind == .done && notification.source != "agent") ? name : Self.title(name, kind: kind)
        self.init(id: notification.notification.rawValue, tab: tab.id, surface: notification.surface?.rawValue,
                  title: programTitle ?? (notification.title.isEmpty ? happened : notification.title),
                  detail: [workspace ?? "", text].filter { !$0.isEmpty }.joined(separator: " · "), kind: kind,
                  reply: tab.kind == .pty ? (Self.takesTypedReply(notification) ? .type : .openTab)
                      : tab.agentSession == nil ? .openTab : .openChat)
    }

    /// A terminal notice the pet may type an answer into: an agent's, or one posted with `--reply`.
    public static func takesTypedReply(_ notification: DaemonNotification) -> Bool {
        notification.reply || notification.source == "agent"
    }
}
