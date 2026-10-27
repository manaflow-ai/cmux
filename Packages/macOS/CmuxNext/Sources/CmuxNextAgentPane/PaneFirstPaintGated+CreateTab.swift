public import CmuxNextSignposts

extension PaneFirstPaintGated {
    /// This content's first paint as a new tab's `create.tab` end (an agent page, a page tab: transparent until its
    /// document paints); `content` is its view in the pane. Content that painted already shows at the commit that
    /// shows it. A view retired before it painted never calls back: its tab's release ends the interval as closed
    /// (`AgentTabStore.release`, `InternalPageTabStore`), and ``CreateTabTimings`` holds the view weakly.
    public func createTabFirstFrame(content: AnyObject) -> CreateTabTimings.FirstFrame {
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
