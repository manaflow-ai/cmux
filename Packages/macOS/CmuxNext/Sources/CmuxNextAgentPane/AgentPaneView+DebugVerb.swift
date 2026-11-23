import Foundation

/// `debug.agent_pane` page verbs: `fn(...args)` on the chat page's `window.cmuxAcpmuxDebug`.
extension AgentPaneView {
    /// Long enough for a 5000-turn load seed and a waited fling of up to ~25 s.
    public nonisolated static let debugVerbDeadline: Duration = .seconds(60)

    /// Runs `fn(...args)` on the page and returns its result as JSON text. A page still loading
    /// gets up to 5 s for its debug hook, on timers: animation frames never come to a page that
    /// draws nothing yet (a chat restored behind its workspace), and that wait held the call to
    /// the 60 s deadline.
    public nonisolated static let debugVerbScript = """
        let debug = window.cmuxAcpmuxDebug;
        for (const end = Date.now() + 5000; !debug && Date.now() < end;) {
            await new Promise((resolve) => setTimeout(resolve, 50));
            debug = window.cmuxAcpmuxDebug;
        }
        if (!debug || typeof debug[fn] !== "function") return JSON.stringify({ error: "the page has no cmuxAcpmuxDebug." + fn });
        return JSON.stringify((await debug[fn](...args)) ?? null);
        """

    /// How long the page call of one verb may run: the verb's deadline less room for its answer to
    /// go back. A Chromium page's script call is a DevTools `Runtime.evaluate`, cut at 5 s unless its
    /// caller names a timeout, so a long seed or a waited fling timed out at 5 s on every run (hq#15602).
    // timeout: room for a debug verb's answer to go back inside its own 60 s deadline; only benches and captures call it
    public nonisolated static let debugVerbPageDeadline: Duration = debugVerbDeadline - .seconds(5)

    /// Runs page verb `function` through `call` (the page's script call: script, arguments, timeout).
    public static func callDebugVerb(_ function: String, args: [Any],
                                     through call: (String, [String: Any], Duration?) async throws -> Any?) async throws -> Any? {
        try await call(debugVerbScript, ["fn": function, "args": args], debugVerbPageDeadline)
    }
}
