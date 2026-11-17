import CmuxNextApps
import CmuxNextSettings
import Foundation
import Testing

/// `page.read`, `page.hints`, `page.follow` (`cmux.page.*`): reader mode and link hints in the app's
/// browser tabs, run as page scripts through `browser.page.eval`.
@MainActor
struct PageAppOpsTests {
    /// A browser that answers `browser.page.eval` by which script it got, and records every call.
    private nonisolated final class Browser: @unchecked Sendable {
        var calls: [(method: String, params: [String: JSONValue])] = []
        /// The labels' token on the page now (`dataset.cmuxApp`).
        var token: JSONValue = .null
        /// The owner key on the labels (`dataset.cmuxOwner`).
        var owner: String?
        /// The built-in `f` session's labels (an overlay with no token) are up.
        var builtIn = false

        /// The string literal that follows `marker` in `script`.
        static func quoted(_ script: String, after marker: String) -> String {
            script.components(separatedBy: marker + "\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
        }
        var targets = #"[{"x":10,"y":20,"left":5,"top":15,"href":"https://example.com/a","text":"First link"},{"x":40,"y":20,"left":35,"top":15,"href":null,"text":"Menu"}]"#
        var page = #"{"url":"https://example.com/","title":"Example","article":{"title":"Example","byline":null,"site":"Ex","blocks":[{"kind":"paragraph","text":"Hello"}]},"links":[{"text":"First link","href":"https://example.com/a"}]}"#

        func answer(_ method: String, _ params: [String: JSONValue]) throws(AppHostCapabilityError) -> JSONValue {
            calls.append((method, params))
            if method == "action.run" { return ["created": ["tab_2"]] }
            guard method == "browser.page.eval", let script = params["script"]?.stringValue else {
                throw AppHostCapabilityError(code: "operation.unsupported", message: method)
            }
            if params["tab"]?.stringValue == "tab_gone" { throw AppHostCapabilityError(code: "not_found", message: "No tab tab_gone") }
            let tab = JSONValue.string(params["tab"]?.stringValue ?? "tab_focused")
            let value: JSONValue
            if script.contains("JSON.stringify({ url: cap(location.href") {
                value = .string(page)
            } else if script.contains("const selector = 'a[href]") {
                value = .string(targets)
            } else if script.contains("host.dataset.cmuxApp = ") {
                if builtIn { return ["tab": tab, "value": "busy"] }
                let drawer = Self.quoted(script, after: "host.dataset.cmuxOwner = ")
                if token != .null, drawer != owner { return ["tab": tab, "value": "taken"] }
                owner = drawer
                token = .string(Self.quoted(script, after: "host.dataset.cmuxApp = "))
                value = true
            } else if script.contains("tokens.includes(token)") {
                // The take script: removes the labels only when their token is listed or they carry the owner key.
                let args = "[" + (script.components(separatedBy: "})(").last?.dropLast() ?? "") + "]"
                let decoded = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [Any]
                let tokens = decoded?.first as? [String] ?? []
                let key = decoded?.last as? String
                guard let shown = token.stringValue, tokens.contains(shown) || (key != nil && key == owner) else {
                    return ["tab": tab, "value": .null]
                }
                token = .null
                value = .string(shown)
            } else if script.contains("elementFromPoint(") {
                value = true
            } else {
                value = .null
            }
            return ["tab": tab, "value": value]
        }

        var evals: [String] { calls.filter { $0.method == "browser.page.eval" }.compactMap { $0.params["script"]?.stringValue } }
    }

    private func makeOps(_ browser: Browser) -> PageAppOps {
        PageAppOps { method, params throws(AppHostCapabilityError) in try browser.answer(method, params) }
    }

    private func request(_ op: String, _ params: AppJSON = [:], origin: String = "user", app: String = "local/reader") -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: app, op: op, params: params, origin: origin, idempotencyKey: "app:local/reader:k1")
    }

    @Test func readAnswersTheReaderScriptsPageWithTheTab() async throws {
        let browser = Browser()
        let value = try await makeOps(browser).handle(request("page.read", origin: "script"))
        #expect(value["tab"] == "tab_focused", "no tab: the focused browser tab")
        #expect(value["title"] == "Example")
        #expect(value["article"]?["blocks"]?.arrayValue?.first?["text"] == "Hello")
        #expect(value["links"]?.arrayValue?.count == 1)
        #expect(browser.calls.map(\.method) == ["browser.page.eval"])
        #expect(browser.calls[0].params["tab"] == nil)

        _ = try await makeOps(browser).handle(request("page.read", ["tab": "tab_7"]))
        #expect(browser.calls[1].params["tab"] == "tab_7")
    }

    @Test func aPageThatDoesNotAnswerJSONIsARetryableFailure() async {
        let browser = Browser()
        browser.page = "not json"
        do {
            _ = try await makeOps(browser).handle(request("page.read"))
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == "operation.failed")
            #expect(error.retryable)
        }
    }

    @Test func hintsShowLabelsEveryClickableElementWithTheBuiltInLabels() async throws {
        let browser = Browser()
        let value = try await makeOps(browser).handle(request("page.hints", ["action": "show"]))
        #expect(value["tab"] == "tab_focused")
        let hints = try #require(value["hints"]?.arrayValue)
        #expect(hints.map { $0["label"]?.stringValue } == ["a", "s"], "the built-in f labels (LinkHintSession.labels)")
        #expect(hints[0]["text"] == "First link")
        #expect(hints[0]["href"] == "https://example.com/a")
        #expect(hints[1]["href"] == AppJSON.null, "a button has no link")
        // Collected, then drawn and marked in the tab the collect ran in.
        #expect(browser.evals.count == 2)
        #expect(browser.calls[1].params["tab"] == "tab_focused")
        #expect(browser.token.stringValue?.isEmpty == false)
    }

    @Test func followClicksTheHintedElementAndClearsTheLabels() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        let value = try await ops.handle(request("page.follow", ["label": "A"]))
        #expect(value == ["tab": "tab_focused", "followed": true, "href": "https://example.com/a"])
        #expect(browser.token == .null, "the labels are gone")
        #expect(browser.evals.last?.contains("elementFromPoint(10") == true, "clicks at the element's center")
        // Followed once: the label is gone.
        let again = try await ops.handle(request("page.follow", ["label": "a"]))
        #expect(again["followed"] == false)
    }

    @Test func followInANewSplitOpensTheLinkLikeTheBuiltInF() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show", "tab": "tab_3"]))
        let none = try await ops.handle(request("page.follow", ["label": "s", "new_split": true, "tab": "tab_3"]))
        #expect(none == ["tab": "tab_3", "followed": false, "href": .null], "a button has no link to open")
        let value = try await ops.handle(request("page.follow", ["label": "a", "new_split": true, "tab": "tab_3"]))
        #expect(value == ["tab": "tab_3", "followed": true, "href": "https://example.com/a"])
        let run = try #require(browser.calls.last)
        #expect(run.method == "action.run")
        #expect(run.params["action"] == "browser.link.openInSplit")
        #expect(run.params["args"]?["url"] == "https://example.com/a")
        #expect(run.params["target"] == "tab:tab_3")
        #expect(run.params["origin"] == "user")
        #expect(run.params["idempotency_key"] == "app:local/reader:k1")
    }

    @Test func followNeverActsOnLabelsItDidNotDraw() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        browser.token = .null // scrolled away, or the built-in f replaced them
        let value = try await ops.handle(request("page.follow", ["label": "a"]))
        #expect(value["followed"] == false)
        #expect(!browser.evals.contains { $0.contains("hit.closest(") })
        let unknown = try await ops.handle(request("page.follow", ["label": "zz"]))
        #expect(unknown["followed"] == false)
    }

    @Test func clearRemovesOnlyAnAppsLabels() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        let value = try await ops.handle(request("page.hints", ["action": "clear"]))
        #expect(value == ["tab": "tab_focused", "hints": []])
        #expect(browser.token == .null, "the app's labels are gone")
        #expect(browser.evals.last?.contains("if (!token || !(tokens.includes(token)") == true, "the built-in f session's labels stay")
    }

    @Test func anotherAppCanNeitherFollowNorClearNorReplaceTheLabels() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        let drawn = browser.token
        let followed = try await ops.handle(request("page.follow", ["label": "a"], app: "local/other"))
        #expect(followed["followed"] == false)
        _ = try await ops.handle(request("page.hints", ["action": "clear"], app: "local/other"))
        do {
            _ = try await ops.handle(request("page.hints", ["action": "show"], app: "local/other"))
            Issue.record("expected a refusal")
        } catch {
            #expect(error.message.contains("another extension"))
        }
        #expect(browser.token == drawn, "the drawing app's labels are still up")
        #expect(!browser.evals.contains { $0.contains("hit.closest(") })
        let mine = try await ops.handle(request("page.follow", ["label": "a"]))
        #expect(mine["followed"] == true, "the drawing app still follows its own label")
    }

    @Test func showNeverTakesDownTheBuiltInLinkHints() async {
        let browser = Browser()
        browser.builtIn = true
        do {
            _ = try await makeOps(browser).handle(request("page.hints", ["action": "show"]))
            Issue.record("expected a refusal")
        } catch {
            #expect(error.code == "operation.failed")
            #expect(error.message.contains("built-in link hints"))
        }
        #expect(browser.token == .null)
    }

    @Test func anAppReplacesAndClearsItsOwnLabels() async throws {
        let browser = Browser()
        let ops = makeOps(browser)
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        let first = browser.token
        _ = try await ops.handle(request("page.hints", ["action": "show"]))
        #expect(browser.token != first, "a second show redraws")
        // Labels the board lost track of (two overlapping shows) still clear by the app's owner key.
        browser.token = "lost"
        _ = try await ops.handle(request("page.hints", ["action": "clear"]))
        #expect(browser.token == .null)
    }

    @Test func badParamsAreRefusedBeforeThePageIsTouched() async {
        let browser = Browser()
        let ops = makeOps(browser)
        for (op, params): (String, AppJSON) in [
            ("page.hints", [:]), ("page.hints", ["action": "toggle"]), ("page.follow", [:]), ("page.follow", ["label": "  "]),
            ("page.follow", ["label": "s", "new_split": "yes"]), ("page.read", ["tab": 3]), ("page.read", ["tab": ""]), ("page.read", "x"),
        ] {
            await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request(op, params)) }
        }
        #expect(browser.calls.isEmpty)
        do {
            _ = try await ops.handle(request("page.eval"))
            Issue.record("expected unsupported")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }

    @Test func aMissingTabIsTheBrowsersRefusal() async {
        do {
            _ = try await makeOps(Browser()).handle(request("page.read", ["tab": "tab_gone"]))
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == "not_found")
        }
    }

    @Test func theRouterSendsThePageFamilyToIt() {
        let router = AppHostCapabilities([PageAppOps { _, _ throws(AppHostCapabilityError) in .null }])
        for op in ["page.read", "page.hints", "page.follow"] { #expect(router.handles(op)) }
        #expect(router.families.contains("page"))
    }
}
