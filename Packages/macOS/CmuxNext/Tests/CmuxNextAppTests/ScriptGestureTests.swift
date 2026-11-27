import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// cmux's own scripts (the hibernation and freeze probes, media actions, recorders) ran in the
/// page's world with a user gesture in both engines (WebKit's evaluateJavaScript forces one;
/// Chromium's Runtime.evaluate had userGesture true for the page world). Each probe gave a hidden
/// page the person's activation: it could then open a popup, start sound, or arm beforeunload
/// without the person. Real WebKit pages; the activation is read without a gesture of its own.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ScriptGestureTests {
    @Test func aCmuxProbeGivesThePageNoActivation() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await Self.page("probed", rig)
        try #require(try await Self.hasBeenActive(page) == false)
        _ = try await BrowserHibernation.probe(page)
        #expect(try await Self.hasBeenActive(page) == false, "a cmux probe gave the page the person's activation")
    }

    /// An agent's script still acts as the user (a click on a target=_blank link opens the tab).
    @Test func anAgentScriptStillActsAsTheUser() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await Self.page("agent", rig)
        // `browser.page.eval` (an agent) runs with `.agent`.
        _ = try await page.evaluate("1", world: .page, gesture: .agent)
        #expect(try await Self.hasBeenActive(page) == true, "an agent's script no longer acts as the user")
    }

    /// cmux's own scripts that went around `evaluate` (review of 0c60222dd4b): Find's match count,
    /// clearing the find selection, leaving pane fullscreen, refusing a fullscreen request made
    /// without the person, and listing the page's links for window hints. Each used a public WebKit
    /// call, which forces a gesture.
    @Test func cmuxScriptsAroundEvaluateGiveThePageNoActivation() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await Self.page("around", rig)
        _ = await page.find("around", direction: .forward, caseSensitive: false)
        page.clearFind()
        page.exitContentFullscreen()
        _ = await WindowHintTargets.pageTargets(of: [page.webView], clip: CGRect(x: 0, y: 0, width: 800, height: 600))
        // The page asks for fullscreen by itself: the refusal runs the exit script.
        _ = try await Self.read("(document.documentElement.requestFullscreen?.(), true)", page)
        // The fire-and-forget scripts have run once a later script answers (one script queue per page).
        _ = try await Self.read("true", page)
        #expect(try await Self.hasBeenActive(page) == false, "a cmux script around evaluate gave the page the person's activation")
    }

    /// Media commands: only those that may start playback act as the user; Pause (which macOS sends
    /// by itself on a headphone unplug), seek and mute do not.
    @Test(arguments: [BrowserMediaCommand.pause, .toggleMute, .seek(1), .muteTab(true)])
    func aMediaCommandThatCannotStartPlaybackGivesNoActivation(_ command: BrowserMediaCommand) async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = try await Self.page("media", rig)
        await page.media(command)
        #expect(try await Self.hasBeenActive(page) == false, "\(command) gave the page the person's activation")
    }

    /// `navigator.userActivation.hasBeenActive`, read without a user gesture.
    static func hasBeenActive(_ page: WebKitTab) async throws -> Bool {
        try await read("navigator.userActivation.hasBeenActive", page) as? Bool ?? false
    }

    /// A loaded page, waited for without a user gesture (the rig's own wait would activate it).
    static func page(_ name: String, _ rig: HiddenPageHibernationTests.Rig) async throws -> WebKitTab {
        let url = rig.folder.appendingPathComponent("\(name).html")
        try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
        let page = rig.services.cache.webKit.makeWebKitTab()
        page.load(url)
        try await rig.until("\(name) loads") { (try? await read("document.readyState", page)) as? String == "complete" }
        return page
    }

    /// A script's value through WebKit's evaluation without a user gesture (every public WKWebView
    /// evaluation forces one, which would activate the page it reads).
    static func read(_ script: String, _ page: WebKitTab) async throws -> Any? {
        let selector = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")
        try #require(page.webView.responds(to: selector), "this WebKit has no evaluation without a gesture")
        typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, @escaping @convention(block) (Any?, (any Error)?) -> Void) -> Void
        let evaluate = unsafeBitCast(page.webView.method(for: selector), to: Evaluate.self)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            evaluate(page.webView, selector, "JSON.stringify(\(script))" as NSString) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value as? String ?? "null") }
            }
        }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }
}
