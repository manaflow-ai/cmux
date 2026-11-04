extension CEFTab {
    /// Answers "Page unresponsive" (``BrowserHangAnswering``) through `cmux_shim_unresponsive_reply`:
    /// wait restarts Chromium's hang timer, terminate ends the renderer (the sad tab follows).
    public func answerUnresponsivePage(terminate: Bool) {
        guard state.isUnresponsive else { return }
        if let browserID { _ = runtime.shim?.unresponsiveReply(browserID, terminate ? 1 : 0) }
        if !terminate { machine.apply(.unresponsiveChanged(false)) }
    }
}
