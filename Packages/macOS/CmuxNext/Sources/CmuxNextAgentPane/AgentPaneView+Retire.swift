public import CmuxNextPages

extension AgentPaneView {
    /// Ends this pane, which no tab shows any more, on the page host's `retirer`: it leaves
    /// the view tree now and its teardown (``close()``: the page, its bridge and observers) runs after the
    /// close's turn, so a Cmd-W frame never pays for it (R81).
    ///
    /// - Parameters:
    ///   - retirer: The page host's retirer (``WebUIHost/retirer``).
    ///   - closed: The tab closed or replaced the page. False when hibernation let a hidden page go: the
    ///     tab stays and the page is asked nothing (it may be frozen), as `WebContents::Discard` asks the
    ///     renderer nothing.
    public func retire(on retirer: PageRetirer, closed: Bool = true) {
        // A closed New Tab page drops the chat a chip pick started behind it; the page stays alive
        // until its teardown, long enough to send the discard.
        if closed { topBar.discardUnsentChat() }
        retirer.retire(self) { [self] in close() }
    }
}
