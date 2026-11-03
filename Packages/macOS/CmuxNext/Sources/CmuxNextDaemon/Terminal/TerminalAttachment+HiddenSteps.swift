/// What a terminal view that hid or shows again sends (``TerminalAttachment/sendHidden(_:)``).
extension TerminalAttachment {
    /// What `sendHidden` sends, in order.
    enum HiddenStep: Equatable, Sendable {
        case sizeCounts(lease: String, counts: Bool?)
        case releaseSize(lease: String)
        case claim
        /// `set-attach-visibility`: the daemon batches a hidden view's output (`attach-visibility-v1`).
        case visibility(Bool)
    }

    /// The commands a view that hid (`hidden`) or shows again sends, given its lease and whether the daemon hides it
    /// in place (`shared-sizing-v1`).
    /// With `attach-visibility-v1` a hidden view's output is batched to once a second: the batching starts after
    /// the view stops counting toward the grid, and ends before it counts again, so a shown view's first frame
    /// follows its waiting output (SWITCH FRAMES SF-5).
    static func hiddenSteps(hidden: Bool, lease: String?, inPlace: Bool, batchesHidden: Bool) -> [HiddenStep] {
        var sizing: [HiddenStep] = []
        if let lease {
            if inPlace {
                sizing = [.sizeCounts(lease: lease, counts: hidden ? false : nil)]
            } else {
                sizing = hidden ? [.releaseSize(lease: lease)] : [.claim]
            }
        }
        guard batchesHidden else { return sizing }
        return hidden ? sizing + [.visibility(false)] : [.visibility(true)] + sizing
    }
}
