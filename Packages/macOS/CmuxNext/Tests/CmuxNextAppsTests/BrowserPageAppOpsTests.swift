import CmuxNextApps
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.eval` from an app (`browserPage.eval`) runs the control socket's
/// `browser.page.eval` with only the script and the tab: an app cannot pose as an agent driver.
struct BrowserPageAppOpsTests {
    private final class Calls: @unchecked Sendable {
        var seen: [(method: String, params: [String: JSONValue], app: String)] = []
    }

    private func make() -> (BrowserPageAppOps, Calls) {
        let calls = Calls()
        let ops = BrowserPageAppOps { method, params, app throws(AppHostCapabilityError) in
            calls.seen.append((method, params, app))
            return .object(["tab": .string("tab_1"), "value": .string("Title")])
        }
        return (ops, calls)
    }

    private func request(_ params: [String: AppJSON]) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/reader-mode", op: "browser.page.eval", params: .object(params), origin: "user")
    }

    @Test func aScriptReachesTheControlVerbWithOnlyScriptAndTab() async throws {
        let (ops, calls) = make()
        #expect(ops.families == ["browser.page"])
        let value = try await ops.handle(request(["script": "document.title", "tab": "tab_1", "agent": "forged"]))
        #expect(value["value"]?.stringValue == "Title")
        #expect(calls.seen.count == 1)
        #expect(calls.seen.first?.method == "browser.page.eval")
        #expect(calls.seen.first?.params == ["script": .string("document.title"), "tab": .string("tab_1")])
        #expect(calls.seen.first?.app == "local/reader-mode")
    }

    @Test func noScriptOrAnOversizedOneIsRefusedBeforeAnyPageRuns() async {
        let (ops, calls) = make()
        let oversized = AppJSON.string(String(repeating: "x", count: BrowserPageAppOps.maxScript + 1))
        for params: [String: AppJSON] in [[:], ["script": ""], ["script": oversized]] {
            do {
                _ = try await ops.handle(request(params))
                Issue.record("a bad page script ran")
            } catch {
                #expect(error.code == "invalid_params")
            }
        }
        #expect(calls.seen.isEmpty)
    }
}
