/// The Home draft attachments each design mode card added, by card id: an edit or a removal on the
/// page takes them back, and a pick whose attachments all left the draft (the person removed its
/// chip, or sent it) leaves the page, as it does from the agent chat.
public struct BrowserDesignModeHomePicks: Sendable, Equatable {
    private var added: [String: [String]] = [:]

    /// No card has added anything yet.
    public init() {}

    /// Records that card `id` added the attachments `hashes` (their chip ids) to the draft.
    public mutating func record(_ id: String, added hashes: [String]) {
        added[id] = hashes
    }

    /// Forgets card `id`.
    /// - Returns: The attachments it added, to take out of the draft; nil when it added none.
    public mutating func take(_ id: String) -> [String]? {
        added.removeValue(forKey: id)
    }

    /// Forgets the cards none of whose attachments is still in the draft, which now holds `draft`.
    /// - Parameter draft: The chip ids of the draft's attachments.
    /// - Returns: Their ids, sorted, to take their picks off the page.
    public mutating func released(keeping draft: [String]) -> [String] {
        let kept = Set(draft)
        let gone = added.filter { !$0.value.isEmpty && kept.isDisjoint(with: $0.value) }.keys.sorted()
        for id in gone { added[id] = nil }
        return gone
    }
}
