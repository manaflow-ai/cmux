public import CmuxNextDaemon
public import CmuxNextFloating

/// The Chief pet's notice from a daemon notification (`NotificationCenterService+ChiefPet` feeds it).
@MainActor
extension ChiefPetNotice {
    /// The notice as the banner reads: the program's or poster's title (else the tab's), and one line of
    /// its text (else the subtitle, else the workspace). A terminal takes a typed reply only for an
    /// agent's notice or one whose poster asked for it (like a `notify --reply` banner); any other
    /// opens its tab (an OSC 9/777 line from a remote shell or a log must not type into what runs there).
    /// An agent chat opens.
    public init(_ notification: DaemonNotification, tab: TabModel, workspace: String?, programTitle: String?, body: String) {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let kind: ChiefPetNotice.Kind = switch notification.level {
        case .warning: .needsYou
        case .error: .failed
        case .info: .done
        }
        self.init(id: notification.notification.rawValue, tab: tab.id, surface: notification.surface?.rawValue,
                  title: programTitle ?? (notification.title.isEmpty ? tab.displayTitle : notification.title),
                  detail: line.isEmpty ? (notification.shownSubtitle ?? workspace ?? "") : line, kind: kind,
                  reply: tab.kind == .pty ? (Self.takesTypedReply(notification) ? .type : .openTab)
                      : tab.agentSession == nil ? .openTab : .openChat)
    }

    /// A terminal notice the pet may type an answer into: an agent's, or one posted with `--reply`.
    public static func takesTypedReply(_ notification: DaemonNotification) -> Bool {
        notification.reply || notification.source == "agent"
    }
}
