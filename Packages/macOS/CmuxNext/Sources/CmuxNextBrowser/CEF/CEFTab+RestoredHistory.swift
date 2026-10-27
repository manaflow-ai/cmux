import Foundation

/// Session history across relaunch (`CEFRestoredSession`), with each entry's page state
/// (`CEFTab+PageState`, task p01-process-093).
extension CEFTab: BrowserSessionRestoring {
    public func restoreSession(_ entries: [BrowserSavedEntry], current: Int) {
        restored.restore(entries, current: current)
    }

    public func currentScrollY() async -> Double? {
        guard case .number(let y)? = try? await evaluate("window.scrollY", world: .isolated, gesture: .cmux) else { return nil }
        return y
    }

    public func savedSession(measuringScroll: Bool) async -> BrowserSavedSession? {
        await restored.savedSession(measuringScroll: measuringScroll)
    }

    /// Changes when a kept page state does, so the history writer saves the tab again.
    public var sessionStateRevision: Int { pageStateRevision }
}
