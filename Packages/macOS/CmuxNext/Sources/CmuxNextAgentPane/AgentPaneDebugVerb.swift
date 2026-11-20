import Foundation

/// One `debug.agent_pane` page verb: `fn(...args)` on the chat page's `window.cmuxAcpmuxDebug`.
public enum AgentPaneDebugVerb {
    /// Long enough for a 5000-turn load seed and a waited fling of up to ~25 s.
    public static let deadline: Duration = .seconds(60)

    /// Runs `fn(...args)` on the page and returns its result as JSON text. A page still loading
    /// gets up to 5 s for its debug hook, on timers: animation frames never come to a page that
    /// draws nothing yet (a chat restored behind its workspace), and that wait held the call to
    /// the 60 s deadline.
    public static let script = """
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
    public static let pageDeadline: Duration = deadline - .seconds(5)

    /// Runs page verb `function` through `call` (the page's script call: script, arguments, timeout).
    public static func call(_ function: String, args: [Any],
                            through call: (String, [String: Any], Duration?) async throws -> Any?) async throws -> Any? {
        try await call(script, ["fn": function, "args": args], pageDeadline)
    }
}
