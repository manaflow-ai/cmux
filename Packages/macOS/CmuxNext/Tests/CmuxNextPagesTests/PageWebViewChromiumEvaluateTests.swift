@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Every script site of a Chromium ``PageWebView`` (``PageWebView/callPageScript(_:arguments:)``,
/// ``PageWebView/callPageFunction(_:arguments:)``, the input-readiness edit) answers through the
/// page's ``PageChromiumPage/evaluate(_:)`` what it answered when the host parsed a
/// `Runtime.evaluate` reply itself: on the DevTools path (``PageChromiumPage/devToolsEvaluate(_:)``)
/// and on the renderer path (`tabEvaluate`), with no DevTools call on the renderer path.
@MainActor
struct PageWebViewChromiumEvaluateTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-evaluate", resource: "chromium-evaluate", processGroup: .solo, namespaces: [])

    /// One value in both forms: the DevTools reply and `tabEvaluate`'s text (`!` marks a throw).
    private typealias Case = (reply: String, renderer: String)

    /// Every kind of value, null, undefined and an exception.
    private static let values: [Case] = [
        (#"{"result":{"type":"string","value":"a\"b"}}"#, #""a\"b""#),
        (#"{"result":{"type":"number","value":5.5}}"#, "5.5"),
        (#"{"result":{"type":"boolean","value":true}}"#, "true"),
        (#"{"result":{"type":"boolean","value":false}}"#, "false"),
        (#"{"result":{"type":"object","value":{"b":[1,null],"a":"x"}}}"#, #"{"a":"x","b":[1,null]}"#),
        (#"{"result":{"type":"object","subtype":"null","value":null}}"#, "null"),
        (#"{"result":{"type":"undefined"}}"#, ""),
        (#"{"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"Error: no"}}}"#, "!Error: no"),
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-evaluate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aPageScriptsResultMatchesTheOldDevToolsPathOnBothPaths() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        for value in Self.values {
            let old = Self.oldScriptResult(value.reply)
            let (devTools, renderer) = await Self.bothPaths(value, marker: "probe", page: page) {
                await Self.result { try await view.callPageScript("return 'probe';") }
            }
            #expect(devTools == old, "DevTools path: \(value.reply)")
            #expect(renderer == old, "renderer path: \(value.reply)")
        }
        view.close()
    }

    /// `callPageFunction` keeps the old path's `NSNull` for null and nil for undefined (as WebKit's
    /// `callAsyncJavaScript`) and nil for an exception.
    @Test func aPageFunctionsResultMatchesTheOldDevToolsPathOnBothPaths() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        for value in Self.values {
            let old = Self.oldFunctionResult(value.reply)
            let (devTools, renderer) = await Self.bothPaths(value, marker: "probe", page: page) {
                Self.text(await view.callPageFunction("return 'probe';"))
            }
            #expect(devTools == old, "DevTools path: \(value.reply)")
            #expect(renderer == old, "renderer path: \(value.reply)")
        }
        view.close()
    }

    /// The type-ahead edit is done only for a boolean `true`, as the old `evaluationIsTrue` parse
    /// decided; the string `"true"`, false, null, undefined and a throw are not done.
    @Test func theInputEditMatchesTheOldDevToolsPathOnBothPaths() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started()
        let editor = try #require(view.inputReadiness.editor)
        let values: [Case] = Self.values + [(reply: #"{"result":{"type":"string","value":"true"}}"#, renderer: #""true""#)]
        for value in values {
            let old = Self.oldEditDone(value.reply)
            let (devTools, renderer) = await Self.bothPaths(value, marker: "insertText", page: page) {
                await editor(.insert("a"), nil)
            }
            #expect(devTools == old, "DevTools path: \(value.reply)")
            #expect(renderer == old, "renderer path: \(value.reply)")
            #expect(page.evaluations.last?.contains("insertText") == true)
        }
        view.close()
    }

    private func started() async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting, deadlines: .testing()))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        return (view, try #require(hosting.made.first))
    }

    /// Runs `call` once on the DevTools path (`value.reply` answers the `Runtime.evaluate` whose
    /// expression has `marker`) and once on the renderer path, which must make no DevTools call.
    private static func bothPaths<T>(_ value: Case, marker: String, page: FakeChromiumPage,
                                     _ call: () async -> T) async -> (devTools: T, renderer: T) {
        let reply = value.reply
        page.rendererEvaluate = nil
        page.answer = { method, params in
            method == "Runtime.evaluate" && (params["expression"] as? String)?.contains(marker) == true ? reply : nil
        }
        let devTools = await call()
        let calls = devToolsCalls(page, marker: marker)
        let renderer = value.renderer
        page.rendererEvaluate = { _ in
            guard renderer.hasPrefix("!") else { return renderer }
            throw PageScriptError.exception(String(renderer.dropFirst()))
        }
        let rendered = await call()
        #expect(devToolsCalls(page, marker: marker) == calls, "the renderer path made a DevTools call")
        page.rendererEvaluate = nil
        return (devTools, rendered)
    }

    /// How many DevTools `Runtime.evaluate` calls ran a script with `marker`.
    private static func devToolsCalls(_ page: FakeChromiumPage, marker: String) -> Int {
        page.calls.filter { $0.method == "Runtime.evaluate" && ($0.params["expression"] as? String)?.contains(marker) == true }.count
    }

    /// The old `callPageScript` parse of a `Runtime.evaluate` reply (before `evaluate`), as text.
    private static func oldScriptResult(_ json: String) -> String {
        guard let object = ChromiumPageHostWire.object(json) else { return "throws noResult" }
        if let details = object["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            return "throws \(exception?["description"] as? String ?? details["text"] as? String ?? "exception")"
        }
        let value = (object["result"] as? [String: Any])?["value"]
        return text(value is NSNull ? nil : value)
    }

    /// The old `callPageFunction` parse: nil for an exception, else the reply's `value` as it is.
    private static func oldFunctionResult(_ json: String) -> String {
        guard let object = ChromiumPageHostWire.object(json), object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any] else { return text(nil) }
        return text(result["value"])
    }

    /// The old edit's parse (`ChromiumPageHostWire.evaluationIsTrue`): done only for a boolean `true`.
    private static func oldEditDone(_ json: String) -> Bool {
        guard let object = ChromiumPageHostWire.object(json), object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any] else { return false }
        return result["value"] as? Bool == true
    }

    /// The result of `call` as text: its value as sorted JSON, or the error it threw.
    private static func result(_ call: () async throws -> Any?) async -> String {
        do {
            return text(try await call())
        } catch PageScriptError.exception(let description) {
            return "throws \(description)"
        } catch {
            return "throws \(error)"
        }
    }

    private static func text(_ value: Any?) -> String {
        guard let value else { return "nil" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return "?" }
        return String(decoding: data, as: UTF8.self)
    }
}
