public import Foundation

/// Design mode on a tab (plans/cmux-next/design-mode-DESIGN.md): classic's runtime in cmux's
/// isolated world, its messages arriving as `.designMode` intents.
extension BrowserTab {
    /// Turns design mode on: readies the engine's message path, then installs and enables the
    /// runtime. The page draws its own hover outline and badges from here on.
    /// - Throws: ``BrowserTabError`` when the tab is closed or the page refused the script.
    public func enableDesignMode(_ script: BrowserDesignModeScript = BrowserDesignModeScript()) async throws {
        let chromium = self is CEFTab
        if let tab = self as? CEFTab { try await tab.agentRelay.prepareDesignMode() }
        _ = try await evaluate(try script.enableScript(chromium: chromium), world: .isolated, gesture: .cmux)
    }

    /// Turns design mode off and puts back every edit it made; harmless when it is off.
    public func disableDesignMode() async {
        _ = try? await evaluate(BrowserDesignModeScript.disableScript, world: .isolated, gesture: .cmux)
    }
}
