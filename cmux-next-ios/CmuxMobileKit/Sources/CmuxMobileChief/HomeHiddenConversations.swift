import Foundation
import Observation

/// Delete Conversation from List and Show Hidden Conversations (the Mac's `home.hideConversation`
/// and `home.showHiddenConversations`): a conversation leaves this account's Home list on this
/// phone until a newer message comes, as the Mac keeps it in its own Home source. Kept per
/// account, like the phone's other list choices; nothing is deleted on the Mac or the service.
@MainActor
@Observable
public final class HomeHiddenConversations {
    public static let shared = HomeHiddenConversations()

    /// Each hidden conversation and the activity time it was hidden at, for the current account.
    public private(set) var hidden: [String: Date] = [:]
    /// Moves with every change of ``hidden`` (Home's list memo keys on it with the rows).
    public private(set) var revision = 0
    @ObservationIgnored private var account: String?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ account: String) -> String { "cmuxMobile.home.hidden.\(account)" }

    /// Reads the account's hidden conversations (nil: signed out, nothing is hidden).
    public func use(account: String?) {
        guard account != self.account else { return }
        self.account = account
        revision &+= 1
        guard let account, let stored = defaults.dictionary(forKey: Self.key(account)) as? [String: Double] else {
            hidden = [:]
            return
        }
        hidden = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Whether `row` stays off the list: it was hidden and no newer message came since.
    public func hides(_ row: MacHomeRow) -> Bool {
        guard let at = hidden[row.id] else { return false }
        return row.activityAt <= at
    }

    /// The rows the list shows.
    public func visible(_ rows: [MacHomeRow]) -> [MacHomeRow] {
        hidden.isEmpty ? rows : rows.filter { !hides($0) }
    }

    /// How many of `rows` are hidden now (Show Hidden Conversations' count).
    public func hiddenCount(in rows: [MacHomeRow]) -> Int {
        hidden.isEmpty ? 0 : rows.count(where: hides)
    }

    /// Delete Conversation from List.
    public func hide(_ row: MacHomeRow) {
        hidden[row.id] = row.activityAt
        revision &+= 1
        save()
    }

    /// Show Hidden Conversations: every hidden conversation lists again.
    public func showAll() {
        hidden = [:]
        revision &+= 1
        save()
    }

    private func save() {
        guard let account else { return }
        if hidden.isEmpty {
            defaults.removeObject(forKey: Self.key(account))
        } else {
            defaults.set(hidden.mapValues(\.timeIntervalSince1970), forKey: Self.key(account))
        }
    }
}
