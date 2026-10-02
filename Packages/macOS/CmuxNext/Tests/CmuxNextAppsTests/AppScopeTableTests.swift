import Testing
@testable import CmuxNextApps

/// The host-side scope check over the generated scopes.json.
struct AppScopeTableTests {
    let table = AppScopeTable.bundled

    @Test func bundledTableLoads() {
        #expect(table.ops["workspace.list"]?.scope == "workspace:read")
        #expect(table.ops.count > 50)
    }

    @Test func readsNeedTheirScope() {
        #expect(table.refusal(op: "workspace.list", params: [:], granted: ["workspace:read"]) == nil)
        let refusal = table.refusal(op: "workspace.list", params: [:], granted: ["agent:read"])
        #expect(refusal?.code == "scope.missing")
        #expect(refusal?.details?["scope"] == "workspace:read")
    }

    @Test func netFetchNeedsAHostScopeAndHTTPS() {
        let granted: Set<String> = ["net:api.github.com", "net:*.example.com"]
        #expect(table.refusal(op: "net.fetch", params: ["url": "https://api.github.com/x"], granted: granted) == nil)
        #expect(table.refusal(op: "net.fetch", params: ["url": "https://a.example.com/"], granted: granted) == nil)
        #expect(table.refusal(op: "net.fetch", params: ["url": "https://example.com/"], granted: granted)?.code == "scope.missing")
        #expect(table.refusal(op: "net.fetch", params: ["url": "http://api.github.com/"], granted: granted)?.code == "invalid_params")
        #expect(table.refusal(op: "net.fetch", params: ["url": "https://evil.com/"], granted: granted)?.details?["scope"] == "net:evil.com")
    }

    @Test func storageIsAlwaysTheAppsOwnAndUnknownOpsAreUnsupported() {
        #expect(table.refusal(op: "app.storage.set", params: [:], granted: []) == nil)
        #expect(table.refusal(op: "teleport.now", params: [:], granted: [])?.code == "operation.unsupported")
        if let never = table.never.first { #expect(table.refusal(op: never, params: [:], granted: [])?.code == "operation.forbidden") }
    }

    @Test func integrationReadScopeCoversGETOnly() {
        let granted: Set<String> = ["integration:github:read"]
        #expect(table.refusal(op: "integration.request", params: ["provider": "github", "method": "GET"], granted: granted) == nil)
        #expect(table.refusal(op: "integration.request", params: ["provider": "github", "method": "POST"], granted: granted)?.code == "scope.missing")
    }

    @Test func allowedOpsFollowTheGrant() {
        let ops = table.allowedOps(granted: ["agent:read"])
        #expect(ops.contains("agent.list"))
        #expect(ops.contains("app.storage.get"))
        #expect(!ops.contains("workspace.list"))
        #expect(!ops.contains("net.fetch"))
    }
}
