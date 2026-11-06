import Foundation

/// How the waiting spare page (`CEFSpareWindow.page`) was frozen, so its take thaws it the same way.
/// A page no one sees must cost no frames, timers or idle CPU: unfrozen, the spare window's
/// placeholder ran rAF at ~98/s at idle (fleet probe 4e065838, macOS 27). The renderer-path freeze
/// (`cmux_shim_tab_set_frozen`, fork API 29) opens no DevTools session, so the page keeps a shareable
/// renderer, but it refuses a page Chromium counts visible; then, and on older forks, DevTools
/// `Page.setWebLifecycleState`, as `CEFTab.freezeNeverShownPage` freezes the placeholder.
enum CEFPageFreeze: Equatable {
    case renderer, devTools

    static func freeze(_ browser: Int32, runtime: CEFRuntime) -> CEFPageFreeze {
        if runtime.forkFeatures.rendererPaths, let setFrozen = runtime.shim?.tabSetFrozen, setFrozen(browser, 1) == 1 { return .renderer }
        runtime.postDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "frozen"])
        return .devTools
    }

    /// Thaws the page in the take's turn, before it moves and shows (`CEFPaneHost.joinSparePage`). The
    /// DevTools thaw keeps the page's call order (`CEFDevToolsCallOrder`): it never passes the freeze.
    func thaw(_ browser: Int32, runtime: CEFRuntime) {
        switch self {
        case .renderer: _ = runtime.shim?.tabSetFrozen?(browser, 0)
        case .devTools: runtime.postDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "active"])
        }
    }
}
