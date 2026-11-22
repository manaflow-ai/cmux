import Foundation

/// What a Home row says about its agent, in the same words as Workspaces
/// (`Workspace.waitingPhrase`): "Chief is asking permission · <preview>",
/// "Chief is working · …", "Done · …". Opt-in (Settings → Home Row Status,
/// ``CmuxMobileHomeRowLook``, off by default): with it off, Home's rows are
/// unchanged. A pure mapping from the row's state, so the tests read it
/// without a view.
struct HomeRowStatus: Equatable, Sendable {
    /// What a waiting agent asks for, when the phone knows (the Mac Chief's pending
    /// question; the Mac's list does not say yet, so other rows read "is waiting").
    enum Ask: Equatable, Sendable {
        case permission
        case question
    }

    /// A waiting agent's open ask: what it asks for and its words ("Allow cargo test -p cnx-link?").
    struct PendingAsk: Equatable, Sendable {
        var kind: Ask
        var text: String
    }

    /// The row's leading mark.
    enum Mark: Equatable, Sendable {
        /// Nothing (a read row).
        case none
        /// The plain unread dot.
        case unread
        /// The needs-you dot (`theme.colors.needsYou`).
        case needsYou
        /// The spinner: the agent runs.
        case working
    }

    enum Kind: Equatable, Sendable {
        case waiting(Ask?)
        case working
        case done
    }

    let kind: Kind
    /// The agent's name, the phrase's subject ("Chief", "Builder").
    let agent: String
    /// The dimmed words after the middle dot: the row's preview.
    let detail: String

    /// The state a row shows, or nil when it says nothing new (an idle, read row,
    /// or a row with no agent): then the preview shows as today.
    static func of(chiefState: MacHomeRow.ChiefState?, ask: Ask?, agent: String, isUnread: Bool,
                   preview: String) -> HomeRowStatus? {
        switch chiefState {
        case .waiting?: HomeRowStatus(kind: .waiting(ask), agent: agent, detail: preview)
        case .working?: HomeRowStatus(kind: .working, agent: agent, detail: preview)
        case .idle?: isUnread ? HomeRowStatus(kind: .done, agent: agent, detail: preview) : nil
        case nil: nil
        }
    }

    /// The bold words before the middle dot.
    var phrase: String {
        switch kind {
        case .waiting(.permission?):
            String(format: String(localized: "mobile.home.status.permission", defaultValue: "%@ is asking permission", bundle: .module), agent)
        case .waiting(.question?):
            String(format: String(localized: "mobile.home.status.question", defaultValue: "%@ has a question", bundle: .module), agent)
        case .waiting(nil):
            String(format: String(localized: "mobile.home.status.waiting", defaultValue: "%@ is waiting", bundle: .module), agent)
        case .working:
            String(format: String(localized: "mobile.home.status.working", defaultValue: "%@ is working", bundle: .module), agent)
        case .done:
            String(localized: "mobile.home.status.done", defaultValue: "Done", bundle: .module)
        }
    }

    /// "Chief is asking permission · Heads up: …", for VoiceOver and tests.
    var line: String { detail.isEmpty ? phrase : "\(phrase) \u{00B7} \(detail)" }

    /// The mark the row leads with when the look moves marks (``CmuxMobileHomeRowLook/movesMark``):
    /// needs-you for a waiting agent, the spinner for a working one, else unread or nothing.
    static func mark(_ status: HomeRowStatus?, isUnread: Bool) -> Mark {
        switch status?.kind {
        case .waiting?: .needsYou
        case .working?: .working
        case .done?, nil: isUnread ? .unread : .none
        }
    }

    /// The pinned tile's bubble with the ask look (``CmuxMobileHomeRowLook/showsAsk``): the pending
    /// question in short form ("Allow cargo test?"), else the waiting phrase, else nil (the tile keeps
    /// its preview bubble).
    static func tileBubble(_ status: HomeRowStatus?, shortAsk: String?) -> String? {
        guard case .waiting? = status?.kind else { return nil }
        if let shortAsk = shortAsk.map({ Self.short($0) }), !shortAsk.isEmpty { return shortAsk }
        return status?.phrase
    }

    /// An ask cut to one short line at a word, at most `limit` characters, with an ellipsis when cut.
    static func short(_ text: String, limit: Int = 32) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "\u{2026}"
    }
}
