public import CmuxNextSignposts

extension PaneFirstPaintGated {
    /// This content's first paint as a new tab's `create.tab` end (an agent page, a page tab: transparent until its
    /// document paints); `content` is its identity in the pane. Content that painted already shows at the commit
    /// that shows it.
    public func createTabFirstFrame(content: ObjectIdentifier) -> CreateTabTimings.FirstFrame {
        guard awaitsFirstPaint else { return .atCommit(content) }
        return .init(content: content) { [weak self] done in
            guard let self else {
                done(.closed)
                return nil
            }
            whenFirstPainted { done(.shown) }
            return nil
        }
    }
}
