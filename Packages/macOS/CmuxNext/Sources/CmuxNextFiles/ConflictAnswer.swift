/// What to do with a ``FileConflict`` (Finder's Keep Both / Stop / Replace, plus Skip).
public enum ConflictChoice: Sendable, Hashable {
    /// Put the new item beside the old one under a numbered name.
    case keepBoth
    /// Remove the old item (to the Trash) and put the new one in its place.
    case replace
    /// Leave this item out and go on.
    case skip
    /// End the whole operation here.
    case stop
}

/// The answer to one conflict, and whether it answers the rest too ("Apply to All").
public struct ConflictAnswer: Sendable, Hashable {
    /// What to do.
    public var choice: ConflictChoice
    /// Use the same choice for every later conflict of this operation.
    public var applyToAll: Bool

    /// Makes an answer.
    public init(_ choice: ConflictChoice, applyToAll: Bool = false) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}
