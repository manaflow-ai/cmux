@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSettings
import AppKit
import Foundation
import Testing

/// 2026-10-28 self-audit: with the person away, the renderer of hidden agent chat pages ran at
/// 23-50 % CPU and 647 MB, because only browser tabs froze when hidden: a chat's page kept
/// rendering every event of every session until its workspace hibernated. A hidden chat's
/// Chromium page now freezes after `browser.freezeHiddenTabs` seconds, as a browser tab does, and
/// thaws when it shows, when its turn starts or waits on the person, and before it is released.
@MainActor @Suite(.serialized)
struct AgentPageFreezeTests {
    /// The Chromium page's freeze control: records every call, and refuses a freeze when told
    /// (the engine still counts the page visible).
    @MainActor final class Page: BrowserFreezing {
        var frozen = false
        var refuses = false
        var calls: [Bool] = []

        func setFrozen(_ frozen: Bool) -> Bool {
            calls.append(frozen)
            if frozen, refuses { return false }
            self.frozen = frozen
            return true
        }
    }

    /// The hibernation rig with every page in Chromium (one freeze control per page).
    static func rig() -> AgentPageHibernationTests.Rig {
        let rig = AgentPageHibernationTests.Rig()
        var pages: [ObjectIdentifier: Page] = [:]
        rig.hibernation.freezer = { view in
            if let page = pages[ObjectIdentifier(view)] { return page }
            let page = Page()
            pages[ObjectIdentifier(view)] = page
            return page
        }
        return rig
    }

    private func advance(_ rig: AgentPageHibernationTests.Rig, seconds: Double) {
        rig.elapsed += .seconds(seconds)
        rig.hibernation.replan()
    }

    private func page(_ rig: AgentPageHibernationTests.Rig, _ key: String) -> Page? {
        guard let view = rig.tabs.existingView(key) else { return nil }
        return rig.hibernation.freezer(view) as? Page
    }

    @Test func aHiddenChatFreezesAfterFreezeSecondsAndThawsWhenShown() throws {
        let rig = Self.rig()
        // The default: no `browser.hibernation` written, so pages are never released, but hidden ones freeze.
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        let view = try rig.hiddenChat("tab_quiet", session: "s-quiet")
        #expect(rig.hibernation.hasFreezeDeadline, "the hide armed no freeze deadline")

        advance(rig, seconds: 20)
        #expect(page(rig, "tab_quiet")?.frozen == false, "froze before freezeHiddenTabs")
        advance(rig, seconds: 11)
        #expect(page(rig, "tab_quiet")?.frozen == true, "a chat hidden past freezeHiddenTabs kept rendering")
        #expect(rig.hibernation.frozen == ["tab_quiet"])
        #expect(rig.tabs.existingView("tab_quiet") === view, "a freeze let the page go")
        #expect(!rig.hibernation.hasFreezeDeadline)

        // Shown again: it thaws before it draws.
        rig.window.contentView?.addSubview(view)
        rig.rendering.insert("tab_quiet")
        rig.hibernation.sync { rig.rendering.contains($0) }
        #expect(page(rig, "tab_quiet")?.frozen == false, "a shown chat stayed frozen")
        #expect(rig.hibernation.frozen.isEmpty)
    }

    @Test func aBusyChatStaysAwakeAndAFrozenChatThawsWhenItsTurnStarts() async throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        _ = try rig.hiddenChat("tab_busy", session: "s-busy")
        _ = try rig.hiddenChat("tab_idle", session: "s-idle")
        rig.turns.setState(.working, session: "s-busy")
        advance(rig, seconds: 31)
        #expect(page(rig, "tab_busy")?.frozen != true, "a chat whose agent works froze")
        #expect(rig.hibernation.keepsAwake("tab_busy") == .agentBusy)
        #expect(page(rig, "tab_idle")?.frozen == true)

        // Its turn starts (or it waits on the person): the frozen page thaws without a show.
        rig.turns.setState(.needsInput, session: "s-idle")
        await rig.settle { self.page(rig, "tab_idle")?.frozen == false }
        #expect(page(rig, "tab_idle")?.frozen == false, "a chat that waits on the person stayed frozen")
        #expect(rig.hibernation.keepsAwake("tab_idle") == .agentBusy)
    }

    @Test func offPinnedAndUnknownTurnsKeepAHiddenChatAwake() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .off), pressure: .normal)
        _ = try rig.hiddenChat("tab_off", session: "s-off")
        advance(rig, seconds: 60)
        #expect(page(rig, "tab_off")?.frozen != true, "hibernation off froze a chat")
        #expect(rig.hibernation.keepsAwake("tab_off") == .disabled)

        rig.hibernation.update(setting: .fallback, pressure: .normal)
        rig.hibernation.isPinned = { $0 == "tab_pinned" }
        _ = try rig.hiddenChat("tab_pinned", session: "s-pinned")
        advance(rig, seconds: 60)
        #expect(page(rig, "tab_pinned")?.frozen != true, "a pinned chat froze")
        #expect(rig.hibernation.keepsAwake("tab_pinned") == .pinned)

        rig.turns.watching = false
        #expect(rig.hibernation.keepsAwake("tab_off") == .agentTurnsUnknown)
    }

    /// The engine still counts the page visible: it stays awake and is asked again
    /// `freezeHiddenTabs` later, as a browser tab is.
    @Test func aRefusedFreezeIsAskedAgainLater() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        _ = try rig.hiddenChat("tab_refused", session: "s-refused")
        let control = try #require(page(rig, "tab_refused"))
        control.refuses = true
        advance(rig, seconds: 31)
        #expect(control.calls == [true])
        #expect(rig.hibernation.frozen.isEmpty)
        #expect(rig.hibernation.hasFreezeDeadline, "a refused freeze armed no second try")
        advance(rig, seconds: 10)
        #expect(control.calls == [true], "asked again before freezeHiddenTabs passed")
        control.refuses = false
        advance(rig, seconds: 21)
        #expect(control.calls == [true, true])
        #expect(control.frozen)
    }

    /// A page built while its tab does not draw (restored or opened in the background) never hid,
    /// so it never froze; now its hidden clock starts at the next plan.
    @Test func aChatBuiltInTheBackgroundFreezesToo() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        rig.hibernation.isRendering = { rig.rendering.contains($0) }
        rig.records["tab_bg"] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", session: "s-bg", harness: "claude")
        _ = try #require(rig.tabs.view(for: "tab_bg"))
        rig.hibernation.replan()
        advance(rig, seconds: 31)
        #expect(page(rig, "tab_bg")?.frozen == true, "a chat built in the background never froze")
    }

    /// Release asks the page what it holds and for its frame: a frozen page thaws first.
    @Test func aFrozenChatThawsBeforeItIsReleased() async throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        _ = try rig.hiddenChat("tab_release", session: "s-release")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_release"))
        #expect(control.frozen)
        rig.advance(minutes: 31)
        await rig.settle { rig.tabs.existingView("tab_release") == nil }
        #expect(rig.tabs.existingView("tab_release") == nil, "the hidden chat kept its page")
        #expect(control.calls == [true, false], "the page was released frozen: \(control.calls)")
    }
}
