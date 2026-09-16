import CmuxControlSocket
import Testing

@Suite("Control-socket resolution admission")
struct ControlClientRateLimiterResolutionTests {
    private static let resolutionMethods = [
        "system.identify", "window.list", "window.current", "window.displays",
        "workspace.list", "workspace.current", "surface.list", "surface.current",
        "pane.list", "pane.surfaces", "list_windows", "current_window",
        "list_workspaces", "current_workspace", "list_surfaces",
    ]

    @Test func targetedTmuxResolutionFanoutDoesNotSpendPollingTokens() async {
        // A frozen clock makes this independent of CPU speed or socket latency.
        let limiter = ControlClientRateLimiter(now: { 0 })
        // display-message -t %pane and split-window resolve the target before
        // mutation; list-panes repeats format-context reads for every pane.
        let targetResolution = ["pane.list", "pane.list", "pane.list", "surface.list"]
        let formatContext = [
            "workspace.list", "surface.current", "pane.surfaces",
            "pane.list", "surface.list",
        ]
        for _ in 0..<20 {
            for method in targetResolution + formatContext {
                #expect(await limiter.admit(method: method) == .allowed, "\(method)")
            }
        }
        #expect(await limiter.admit(method: "surface.split") == .allowed)
        #expect(await limiter.admit(method: "surface.send_text") == .allowed)
        for _ in 0..<ControlClientRateLimiter.Configuration().burst {
            #expect(await limiter.admit(method: "system.top") == .allowed)
        }
        #expect(await limiter.admit(method: "system.top") == .limited(retryAfterMilliseconds: 100))
    }

    @Test(arguments: resolutionMethods)
    func exhaustedPollingBucketCannotBlockTargetResolution(method: String) async {
        let limiter = ControlClientRateLimiter(configuration: .init(burst: 1), now: { 0 })
        #expect(await limiter.admit(method: "system.top") == .allowed)
        for _ in 0..<3 {
            #expect(await limiter.admit(method: method) == .allowed)
        }
        // Resolution neither consumes nor replenishes the diagnostic budget.
        #expect(await limiter.admit(method: "system.top") == .limited(retryAfterMilliseconds: 100))
    }

    @Test(arguments: [
        "system.top", "system.memory", "system.tree",
        "surface.read_text", "surface.read_selection", "read_screen",
    ])
    func expensivePollingStillHasBackpressure(method: String) async {
        let limiter = ControlClientRateLimiter(configuration: .init(burst: 1), now: { 0 })
        #expect(await limiter.admit(method: method) == .allowed)
        #expect(await limiter.admit(method: method) == .limited(retryAfterMilliseconds: 100))
    }
}
