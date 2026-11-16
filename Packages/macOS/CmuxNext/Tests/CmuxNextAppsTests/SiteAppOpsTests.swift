import CmuxNextApps
import Foundation
import Testing

/// The `browser.site` family (`browser.site.javascript.*`) over a fake browser, and the
/// `apps-site-styles` snapshot the app keeps for document commits.
@MainActor
struct SiteAppOpsTests {
    private final class Browser: @unchecked Sendable {
        /// Tab id -> its document origin (nil: a page with none).
        var tabs: [String: String?] = [:]
        var selected: String?
        var javaScript: [String: Bool] = [:]
        var sets: [(origin: String, tab: String?, allowed: Bool)] = []

        var host: SiteAppHost {
            SiteAppHost(tabOrigin: { [unowned self] id in
                guard let id = id ?? selected else { return nil }
                return tabs[id]
            }, origin: { raw in
                raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : nil
            }, javaScriptAllowed: { [unowned self] origin, _ in javaScript[origin] ?? true }, setJavaScript: { [unowned self] origin, tab, allowed in
                javaScript[origin] = allowed
                sets.append((origin, tab, allowed))
            })
        }
    }

    private func request(_ op: String, _ params: AppJSON) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/showcase-site-js", op: op, params: params, origin: "user")
    }

    private func code(_ ops: SiteAppOps, _ op: String, _ params: AppJSON) async -> String? {
        do {
            _ = try await ops.handle(request(op, params))
            return nil
        } catch {
            return error.code
        }
    }

    @Test func theRouterSendsTheDottedFamilyToIt() async throws {
        let browser = Browser()
        browser.tabs["t1"] = "https://a.test"
        let router = AppHostCapabilities([SiteAppOps(host: browser.host), ToastAppOps { _ in true }])
        #expect(router.families.contains("browser.site"))
        #expect(router.handles("browser.site.javascript.set"))
        #expect(!router.handles("browser.tab.list"), "the rest of browser.* is the daemon's")
        #expect(router.handles("toast.show"), "one-word families still route")
        let value = try await router.handle(request("browser.site.javascript.get", ["tab": "t1"]))
        #expect(value == ["origin": "https://a.test", "allowed": true])
    }

    @Test func javaScriptGetAndSetUseTheOriginOrTheTabsOrigin() async throws {
        let browser = Browser()
        browser.tabs["t1"] = "https://a.test"
        browser.selected = "t1"
        let ops = SiteAppOps(host: browser.host)
        #expect(try await ops.handle(request("browser.site.javascript.get", [:])) == ["origin": "https://a.test", "allowed": true])
        #expect(try await ops.handle(request("browser.site.javascript.set", ["allowed": false])) == ["origin": "https://a.test", "allowed": false])
        #expect(try await ops.handle(request("browser.site.javascript.get", ["origin": "https://a.test"])) == ["origin": "https://a.test", "allowed": false])
        #expect(try await ops.handle(request("browser.site.javascript.set", ["origin": "https://b.test", "tab": "t1", "allowed": true])) == ["origin": "https://b.test", "allowed": true])
        #expect(browser.sets.map(\.origin) == ["https://a.test", "https://b.test"])
        #expect(browser.sets.last?.tab == "t1")
    }

    @Test func javaScriptRefusesBadParamsAndPagesWithoutAWebOrigin() async {
        let browser = Browser()
        let ops = SiteAppOps(host: browser.host)
        #expect(await code(ops, "browser.site.javascript.get", [:]) == "page.none")
        #expect(await code(ops, "browser.site.javascript.get", ["tab": "t9"]) == "page.none")
        #expect(await code(ops, "browser.site.javascript.get", ["tab": 3]) == "validation.invalid")
        #expect(await code(ops, "browser.site.javascript.set", ["origin": "https://a.test"]) == "validation.invalid", "allowed is required")
        #expect(await code(ops, "browser.site.javascript.set", ["origin": "https://a.test", "allowed": "no"]) == "validation.invalid")
        #expect(await code(ops, "browser.site.javascript.get", ["origin": "file:///etc"]) == "validation.invalid")
        browser.tabs["local"] = .some(nil)
        browser.selected = "local"
        #expect(await code(ops, "browser.site.javascript.get", [:]) == "validation.invalid")
        #expect(browser.sets.isEmpty)
        #expect(await code(ops, "browser.site.style.set", [:]) == "operation.unsupported", "styles are the daemon's")
    }

    @Test func aSnapshotReplacesTheLastAndARemovalRunsOnceThenIsForgotten() {
        var snapshot = SiteStyleSnapshot()
        let first: AppJSON = ["event": "apps-site-styles", "styles": [
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
        let installers = SiteStyleSnapshot.installers(second)
        #expect(installers.now == ["https://a.test": ["remove-a", "install-a2"]], "what runs on open tabs, in order")
        #expect(installers.kept == ["https://a.test": ["install-a2"]], "what later commits run")
        #expect(snapshot.replace(with: ["styles": []]).isEmpty)
        #expect(snapshot.entries.isEmpty)
    }
}
