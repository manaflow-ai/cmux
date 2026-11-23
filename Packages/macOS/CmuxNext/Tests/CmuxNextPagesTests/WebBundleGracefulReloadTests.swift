@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// A web layer change (a customization put on, `cmux customize use`, the dev server) reloads each open
/// page at its own safe point, not all at once: Leo's agent pane reloaded under him while he talked to a
/// coordinator (2026-11-22: "my composer is ideally untouched as much as possible. likewise with my
/// drafts").
@MainActor
@Suite(.serialized)
struct WebBundleGracefulReloadTests {
    @Test func aPageThatMayReloadReloadsAtOnce() async {
        let reloader = WebBundleGracefulReload()
        reloader.booksLooks = false
        let free = WKWebView(), noHook = WKWebView(), silent = WKWebView()
        var reloaded: [ObjectIdentifier] = []
        reloader.askOverride = { views in views.map { $0 === noHook ? "page.no-hook" : $0 === silent ? "page.no-answer" : nil } }
        reloader.reloadOverride = { reloaded.append(ObjectIdentifier($0)) }
        reloader.reload([free, noHook, silent], to: nil, served: WebBundleServedViews())
        await reloader.look()
        #expect(Set(reloaded) == Set([free, noHook, silent].map(ObjectIdentifier.init)))
        #expect(reloader.waitingCount == 0)
    }

    @Test func aPageHoldingTextWaitsUntilItIsDone() async {
        let reloader = WebBundleGracefulReload()
        reloader.booksLooks = false
        let typing = WKWebView(), idle = WKWebView()
        var answer: String? = "field"
        var reloaded: [ObjectIdentifier] = []
        reloader.askOverride = { views in views.map { $0 === typing ? answer : nil } }
        reloader.reloadOverride = { reloaded.append(ObjectIdentifier($0)) }
        reloader.reload([typing, idle], to: nil, served: WebBundleServedViews())
        await reloader.look()
        #expect(reloaded == [ObjectIdentifier(idle)])
        #expect(reloader.waitingCount == 1)
        answer = nil
        await reloader.look()
        #expect(reloaded == [ObjectIdentifier(idle), ObjectIdentifier(typing)])
        #expect(reloader.waitingCount == 0)
    }

    @Test func onlyWhatAReloadDisturbsGivesWayPastTheLimit() {
        let past = WebBundleGracefulReload.disturbLimit
        #expect(WebBundleGracefulReload.mayReload(nil, waited: .zero))
        #expect(!WebBundleGracefulReload.mayReload("scroll", waited: .zero))
        #expect(WebBundleGracefulReload.mayReload("scroll", waited: past))
        #expect(WebBundleGracefulReload.mayReload("caret", waited: past))
        // Lost text, input being composed or a send on the way never give way.
        #expect(!WebBundleGracefulReload.mayReload("field", waited: .seconds(3600)))
        #expect(!WebBundleGracefulReload.mayReload("ime", waited: .seconds(3600)))
        #expect(!WebBundleGracefulReload.mayReload("composer.sending", waited: .seconds(3600)))
    }

    @Test func aLaterChangeReplacesTheViewsStillWaiting() async {
        let reloader = WebBundleGracefulReload()
        reloader.booksLooks = false
        let first = WKWebView(), second = WKWebView()
        reloader.askOverride = { views in views.map { _ in "field" } }
        reloader.reloadOverride = { _ in }
        reloader.reload([first], to: nil, served: WebBundleServedViews())
        await reloader.look()
        #expect(reloader.waitingCount == 1)
        reloader.reload([first, second], to: nil, served: WebBundleServedViews())
        #expect(reloader.waitingCount == 2)
        reloader.reload([], to: nil, served: WebBundleServedViews())
        #expect(reloader.waitingCount == 0)
    }
}
