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

extension CEFTab {
    /// The committing document's request was a POST (a form), by the shim's
    /// record of the last main-frame request (BR-R1).
    var documentCameFromPost: Bool {
        guard let browserID, let shim = runtime.shim else { return false }
        return shim.tabDocumentFromPost(browserID) == 1
    }
}
