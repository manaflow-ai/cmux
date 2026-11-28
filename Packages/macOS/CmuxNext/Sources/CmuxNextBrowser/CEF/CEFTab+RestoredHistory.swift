import Foundation

/// Session history across relaunch (`CEFRestoredSession`).
extension CEFTab: BrowserSessionRestoring {
    public func restoreSession(_ entries: [BrowserSavedEntry], current: Int) {
        restored.restore(entries, current: current)
    }

    public func currentScrollY() async -> Double? {
        guard case .number(let y)? = try? await evaluate("window.scrollY", world: .isolated) else { return nil }
        return y
    }

    public func savedSession(measuringScroll: Bool) async -> BrowserSavedSession? {
        await restored.savedSession(measuringScroll: measuringScroll)
    }
}
