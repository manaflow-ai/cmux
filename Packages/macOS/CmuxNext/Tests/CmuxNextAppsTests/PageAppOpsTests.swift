import CmuxNextApps
import Foundation
import Testing

/// The `page` family (`page.read`, `page.javascript.*`) over a fake browser, and the
/// `apps-page-styles` snapshot the app keeps for document commits.
@MainActor
struct PageAppOpsTests {
    private final class Browser: @unchecked Sendable {
        var tabs: [String: PageAppTab] = [:]
        var selected: String?
        var scripts: [String] = []
        var javaScript: [String: Bool] = [:]
        var sets: [(origin: String, tab: String?, allowed: Bool)] = []

        func add(_ id: String, url: String, origin: String?, value: AppJSON = ["candidates": [], "truncated": false]) {
            tabs[id] = PageAppTab(id: id, url: url, origin: origin, title: "Title \(id)") { [unowned self] script in
                scripts.append(script)
                return value
            }
        }

        var host: PageAppHost {
            PageAppHost(tab: { [unowned self] id in id.map { tabs[$0] } ?? selected.flatMap { tabs[$0] } }, origin: { raw in
                raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : nil
            }, javaScriptAllowed: { [unowned self] origin, _ in javaScript[origin] ?? true }, setJavaScript: { [unowned self] origin, tab, allowed in
                javaScript[origin] = allowed
                sets.append((origin, tab, allowed))
            })
        }
    }

    private func request(_ op: String, _ params: AppJSON) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/showcase-clean-page", op: op, params: params, origin: "user")
    }

    private func code(_ ops: PageAppOps, _ op: String, _ params: AppJSON) async -> String? {
        do {
            _ = try await ops.handle(request(op, params))
            return nil
        } catch {
            return error.code
        }
    }

    @Test func theRouterSendsThePageFamilyToIt() {
        let router = AppHostCapabilities([PageAppOps(host: Browser().host)])
        #expect(router.families.contains("page"))
        #expect(router.handles("page.read"))
        #expect(router.handles("page.javascript.set"))
    }

    @Test func readRunsTheDaemonsScriptOnTheSelectedTabAndMergesTheTab() async throws {
        let browser = Browser()
        browser.add("t1", url: "https://a.test/x", origin: "https://a.test", value: ["candidates": [["selector": "#ad"]], "truncated": false, "url": "spoofed"])
        browser.selected = "t1"
        let ops = PageAppOps(host: browser.host)
        let value = try await ops.handle(request("page.read", ["script": "(() => ({}))()"]))
        #expect(browser.scripts == ["(() => ({}))()"])
        #expect(value["tab"] == "t1")
        #expect(value["url"] == "https://a.test/x", "the tab's own fields win over the script's")
        #expect(value["origin"] == "https://a.test")
        #expect(value["title"] == "Title t1")
        #expect(value["truncated"] == false)
        #expect(value["candidates"]?.arrayValue?.count == 1)
    }

    @Test func readNamesATabOrRefusesWithPageNone() async {
        let browser = Browser()
        let ops = PageAppOps(host: browser.host)
        #expect(await code(ops, "page.read", ["script": "1"]) == "page.none")
        browser.add("t2", url: "https://b.test/", origin: "https://b.test")
        #expect(await code(ops, "page.read", ["script": "1", "tab": "t2"]) == nil)
        #expect(await code(ops, "page.read", ["script": "1", "tab": "t9"]) == "page.none")
        #expect(await code(ops, "page.read", ["tab": "t2"]) == "validation.invalid", "the daemon always sends a script")
        #expect(await code(ops, "page.read", ["script": "1", "tab": 3]) == "validation.invalid")
        browser.add("t3", url: "https://c.test/", origin: "https://c.test", value: "not an object")
        #expect(await code(ops, "page.read", ["script": "1", "tab": "t3"]) == "operation.failed")
    }

    @Test func javaScriptGetAndSetUseTheOriginOrTheTabsOrigin() async throws {
        let browser = Browser()
        browser.add("t1", url: "https://a.test/x", origin: "https://a.test")
        browser.selected = "t1"
        let ops = PageAppOps(host: browser.host)
        #expect(try await ops.handle(request("page.javascript.get", [:])) == ["origin": "https://a.test", "allowed": true])
        #expect(try await ops.handle(request("page.javascript.set", ["allowed": false])) == ["origin": "https://a.test", "allowed": false])
        #expect(try await ops.handle(request("page.javascript.get", ["origin": "https://a.test"])) == ["origin": "https://a.test", "allowed": false])
        #expect(try await ops.handle(request("page.javascript.set", ["origin": "https://b.test", "tab": "t1", "allowed": true])) == ["origin": "https://b.test", "allowed": true])
        #expect(browser.sets.map(\.origin) == ["https://a.test", "https://b.test"])
        #expect(browser.sets.last?.tab == "t1")
    }

    @Test func javaScriptRefusesBadParamsAndPagesWithoutAWebOrigin() async {
        let browser = Browser()
        let ops = PageAppOps(host: browser.host)
        #expect(await code(ops, "page.javascript.get", [:]) == "page.none")
        #expect(await code(ops, "page.javascript.set", ["origin": "https://a.test"]) == "validation.invalid", "allowed is required")
        #expect(await code(ops, "page.javascript.set", ["origin": "https://a.test", "allowed": "no"]) == "validation.invalid")
        #expect(await code(ops, "page.javascript.get", ["origin": "file:///etc"]) == "validation.invalid")
        browser.add("local", url: "about:blank", origin: nil)
        browser.selected = "local"
        #expect(await code(ops, "page.javascript.get", [:]) == "validation.invalid")
        #expect(browser.sets.isEmpty)
        #expect(await code(ops, "page.style.set", [:]) == "operation.unsupported", "styles are the daemon's")
    }

    @Test func aSnapshotReplacesTheLastAndARemovalRunsOnceThenIsForgotten() {
        var snapshot = PageStyleSnapshot()
        let first: AppJSON = ["event": "apps-page-styles", "styles": [
            ["app": "local/x", "origin": "https://a.test", "css": ".ad{display:none}", "source": "install-a"],
            ["app": "local/y", "origin": "https://a.test", "css": "header{position:static}", "source": "install-a2"],
            ["app": "local/x", "origin": "https://b.test", "css": ".b{display:none}", "source": "install-b"],
            ["app": "local/x", "origin": "https://c.test", "css": ".c{}"],
        ]]
        #expect(snapshot.replace(with: first).map(\.source) == ["install-a", "install-a2", "install-b"], "an entry without a source is dropped")
        #expect(snapshot.sources(for: "https://a.test") == ["install-a", "install-a2"])
        #expect(snapshot.sources(for: "https://b.test") == ["install-b"])
        let second: AppJSON = ["styles": [
            ["app": "local/x", "origin": "https://a.test", "css": "", "source": "remove-a"],
            ["app": "local/y", "origin": "https://a.test", "css": "header{position:static}", "source": "install-a2"],
        ]]
        let run = snapshot.replace(with: second)
        #expect(run.map(\.source) == ["remove-a", "install-a2"], "the removal runs on open tabs now")
        #expect(run.first?.isRemoval == true)
        #expect(snapshot.sources(for: "https://a.test") == ["install-a2"], "and is not kept for later commits")
        #expect(snapshot.sources(for: "https://b.test").isEmpty, "the full snapshot replaces the last one")
        #expect(snapshot.replace(with: ["styles": []]).isEmpty)
        #expect(snapshot.entries.isEmpty)
    }
}
