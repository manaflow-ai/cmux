public import CmuxNextDaemon
import Foundation

/// One agent event the Chief pet shows above itself: the notification a tab
/// holds unread, as its banner would read.
public struct ChiefPetNotice: Equatable, Identifiable {
    public enum Kind: Equatable {
        /// An agent asks for input or approval (a warning).
        case needsYou
        /// Something failed (an error).
        case failed
        /// A turn finished, or any other notice (info).
        case done

        init(_ level: NotificationLevel) {
            switch level {
            case .warning: self = .needsYou
            case .error: self = .failed
            case .info: self = .done
            }
        }

        /// Waits for the user: stays up until its tab is read, and counts on the badge.
        var waits: Bool { self != .done }
    }

    /// How the pet's reply box answers it.
    public enum Reply: Equatable {
        /// Typed text goes into its terminal, then Return (a `notify --reply` banner's path).
        case type
        /// Its agent chat opens to answer in (a prompt is sent only from the chat's own composer).
        case openChat
        /// Only opening its tab.
        case openTab
    }

    /// The daemon's notification id.
    public let id: UInt64
    /// The tab that holds it; one notice per tab.
    public let tab: String
    public let surface: SurfaceID?
    public let title: String
    public let detail: String
    public let kind: Kind
    public var reply: Reply = .openTab
    /// The agent chat's session, for `openChat`.
    public var session: String?

    public init(id: UInt64, tab: String, surface: SurfaceID?, title: String, detail: String, kind: Kind,
                reply: Reply = .openTab, session: String? = nil) {
        self.id = id
        self.tab = tab
        self.surface = surface
        self.title = title
        self.detail = detail
        self.kind = kind
        self.reply = reply
        self.session = session
    }

    /// The notice as the banner reads: the program's or poster's title (else the tab's), and
    /// one line of its text (else the subtitle, else the workspace).
    public init(_ notification: DaemonNotification, tab: String, tabTitle: String, workspace: String?, programTitle: String?, body: String,
                reply: Reply = .openTab, session: String? = nil) {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        self.init(id: notification.notification.rawValue, tab: tab, surface: notification.surface,
                  title: programTitle ?? (notification.title.isEmpty ? tabTitle : notification.title),
                  detail: line.isEmpty ? (notification.shownSubtitle ?? workspace ?? "") : line, kind: Kind(notification.level),
                  reply: reply, session: session)
    }

    /// What the bubble draws: the same content shown again is not a new arrival.
    var content: [String] { [title, detail, "\(kind)"] }
}

/// The pet's notices, newest first, at most one per tab. Pure: the
/// controller feeds it arrivals, reads and expiries and draws `front`.
struct ChiefPetFeed: Equatable {
    /// The bubble's deck shows this many at most.
    static let limit = 3

    private(set) var notices: [ChiefPetNotice] = []

    /// What an arrival changed for the bubble.
    enum Change: Equatable {
        /// Nothing to redraw: the tab already shows that content.
        case unchanged
        /// A new front notice (it enters with the bubble's one-time motion).
        case arrived
    }

    var front: ChiefPetNotice? { notices.first }

    /// Notices that wait for the user (the pet's badge).
    var attention: Int { notices.count(where: { $0.kind.waits }) }

    @discardableResult
    mutating func arrive(_ notice: ChiefPetNotice) -> Change {
        let previous = notices.firstIndex { $0.tab == notice.tab }
        // Identical content on the front notice never re-animates; it only takes the newer id.
        if let previous, previous == 0, notices[0].content == notice.content {
            notices[0] = notice
            return .unchanged
        }
        if let previous { notices.remove(at: previous) }
        notices.insert(notice, at: 0)
        if notices.count > Self.limit {
            // A notice that waits outlives a finished one past the limit.
            let drop = notices.lastIndex { !$0.kind.waits } ?? notices.count - 1
            notices.remove(at: drop)
        }
        return .arrived
    }

    /// `tab` was read (opened, answered, dismissed): its notice goes.
    mutating func read(tab: String) {
        notices.removeAll { $0.tab == tab }
    }

    /// A finished notice's time is up; a newer notice on its tab stays.
    mutating func expire(id: UInt64) {
        notices.removeAll { $0.id == id && !$0.kind.waits }
    }

    mutating func clear() {
        notices.removeAll()
    }
}

/// Where the Chief pet hears agent events: what alerts on this Mac, and which tabs were read.
public struct ChiefPetHooks {
    public var alerted: @MainActor (ChiefPetNotice) -> Void
    public var read: @MainActor (_ tab: String) -> Void
}
