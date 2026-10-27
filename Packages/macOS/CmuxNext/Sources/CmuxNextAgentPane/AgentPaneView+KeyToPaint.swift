import CmuxNextPages

extension AgentPaneView {
    /// Turns the page's key-to-paint probe (`window.cmuxKeyToPaint`, webviews/src/ui/frameInput.ts) on
    /// or off; while on, its histograms reach ``keyToPaintReport``. A frozen page is not woken: it
    /// runs the newest state on thaw, and it has no keys to measure until then.
    public func setKeyToPaintProbe(_ on: Bool) {
        page.evaluate(on ? Self.keyToPaintOnScript : Self.keyToPaintOffScript, whileFrozen: .latest(.keyToPaintProbe))
    }

    private static let keyToPaintOnScript = "globalThis.cmuxKeyToPaint?.setEnabled(true);"
    private static let keyToPaintOffScript = "globalThis.cmuxKeyToPaint?.setEnabled(false);"
}

nonisolated extension PagePushKind {
    /// The agent page's key-to-paint probe switch (``AgentPaneView/setKeyToPaintProbe(_:)``).
    static let keyToPaintProbe = PagePushKind("agent.keyToPaintProbe")
}
