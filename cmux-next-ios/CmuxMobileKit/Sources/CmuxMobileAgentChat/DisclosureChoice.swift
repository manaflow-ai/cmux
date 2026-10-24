/// A row that opens on its own (a live thought shows its last lines) until
/// the person taps it: from then on their choice holds, so a tap always
/// closes what is open. A live thought used to keep its text on screen
/// after a tap with the chevron turned to closed.
struct DisclosureChoice: Equatable {
    /// The person's choice; nil follows `automatic`.
    private(set) var chosen: Bool?

    func isOpen(automatic: Bool) -> Bool { chosen ?? automatic }

    mutating func toggle(automatic: Bool) {
        chosen = !isOpen(automatic: automatic)
    }
}
