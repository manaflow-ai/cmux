import Foundation

extension CloudStartCore {
    /// Whether a Cloud start that is not an agent chat's (a terminal's or a script's `cmux cloud start-session`,
    /// and `cmux cloud start-chat` through it) starts as the person's Start would: their gesture (`byPerson`), or
    /// any run while they let agents start Cloud sessions without asking (`delegated`: `cloud.agentsStartWithoutAsking`,
    /// on by default), since an agent in a terminal looks like the person there. Then its machine is created with
    /// no "Create a Cloud machine?" card, as an agent chat's run already is (`CloudStartSession.agentAsk`), instead
    /// of waiting on a card nobody sees until the run answers pending. Leo, 2026-11-04: "it had this prompt idk if we want that".
    public func startsAsPerson(byPerson: Bool, delegated: Bool) -> Bool {
        byPerson || !agentAsksFirst(delegated: delegated)
    }
    /// A personal send (`account`'s team nil) on a non-production sign-in copies through the content-addressed store.
    public func copiesThroughStore(account: [String?], productionAuth: Bool) -> Bool { (account.last ?? nil) == nil && !productionAuth }
    /// `text` as one shell word: as it is when it is a plain name, else in single quotes.
    public static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard text.isEmpty || !text.unicodeScalars.allSatisfy(plain.contains) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
