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
        // As the App wires the store (`AgentTabStore.onPageBuilt`).
        rig.tabs.onPageBuilt = { rig.hibernation.pageBuilt($0) }
        rig.records["tab_bg"] = AgentSessionRef(host: AgentPageHibernationTests.thisMac, hostName: "This Mac", session: "s-bg", harness: "claude")
        _ = try #require(rig.tabs.view(for: "tab_bg"))
        // The build itself started the clock and armed the deadline: no other event comes.
        #expect(rig.hibernation.hasFreezeDeadline, "a chat built in the background armed no freeze deadline")
        advance(rig, seconds: 31)
        #expect(page(rig, "tab_bg")?.frozen == true, "a chat built in the background never froze")
    }

    /// The frame pacer sends a hidden page the pushes it waits on (a reply, a turn's end, a
    /// backlog): a frozen page thaws before the push goes, and freezes again once idle that long.
    @Test func aPushForAFrozenChatThawsItFirst() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        let view = try rig.hiddenChat("tab_push", session: "s-push")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_push"))
        #expect(control.frozen)
        let wake = try #require(view.model.transport.beforePageWork, "a frozen page's transport has no wake")
        wake()
        #expect(!control.frozen, "a push went to a frozen page")
        #expect(view.model.transport.beforePageWork == nil)
        advance(rig, seconds: 20)
        #expect(!control.frozen, "froze again before freezeHiddenTabs")
        advance(rig, seconds: 11)
        #expect(control.frozen, "a page woken for a push never froze again")
    }

    /// A Chromium page's browser is made after its view: until then it has no freeze control. The
    /// page is still planned, and freezes once its browser is there, with no other event.
    @Test func aChatWhoseBrowserIsStillBeingMadeFreezesOnceItIsThere() throws {
        let rig = AgentPageHibernationTests.Rig()
        var attached = false
        let control = Page()
        rig.hibernation.freezer = { _ in attached ? control : nil }
        rig.hibernation.waitsForFreezer = { _ in !attached }
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        _ = try rig.hiddenChat("tab_slow", session: "s-slow")
        #expect(rig.hibernation.hasFreezeDeadline, "a page still making its browser armed no freeze deadline")
        advance(rig, seconds: 31)
        #expect(control.calls.isEmpty)
        #expect(rig.hibernation.hasFreezeDeadline, "a due page with no browser yet was not looked at again")
        attached = true
        advance(rig, seconds: 1)
        #expect(control.frozen, "the page froze neither when due nor once its browser was there")
    }

    /// The quit asks every chat page what it holds for the next launch (`relaunchWakeStates`): a
    /// frozen page thaws first and none freezes until that ends.
    @Test func theQuitsRelaunchStateThawsFrozenChatsAndKeepsThemAwake() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        _ = try rig.hiddenChat("tab_quit", session: "s-quit")
        _ = try rig.hiddenChat("tab_later", session: "s-later")
        advance(rig, seconds: 31)
        let frozen = try #require(page(rig, "tab_quit"))
        #expect(frozen.frozen)
        rig.hibernation.holdAwake(true)
        #expect(!frozen.frozen, "a frozen page was asked for its relaunch state")
        #expect(rig.hibernation.keepsAwake("tab_quit") == .disabled)
        advance(rig, seconds: 60)
        #expect(!frozen.frozen, "a page froze while the quit collected its state")
        rig.hibernation.holdAwake(false)
        #expect(frozen.frozen, "a page still hidden past freezeHiddenTabs stayed awake after the quit's collection")
    }

    /// A provisional tab's creation answers after its hidden page froze: the page moves to the
    /// store's key (`AgentTabStore.rekey`) and the alias goes later. The page thaws instead of
    /// being forgotten frozen, freezes again under its new key, and a turn or the quit still reaches it.
    @Test func aFrozenChatWhoseTabGetsItsRealKeyIsNotLostFrozen() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        rig.hibernation.isRendering = { rig.rendering.contains($0) }
        let view = try rig.hiddenChat("tab_provisional", session: "s-rekey")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_provisional"))
        #expect(control.frozen)

        rig.records["tab_real"] = rig.records["tab_provisional"]
        rig.tabs.rekey("tab_provisional", to: "tab_real")
        rig.tabs.aliases["tab_provisional"] = nil
        #expect(rig.tabs.existingView("tab_real") === view)
        // With no plan since the rekey, a push still finds the page.
        let wake = try #require(view.model.transport.beforePageWork, "the rekeyed page lost its wake")
        wake()
        #expect(!control.frozen, "a push did not wake the rekeyed page")
        #expect(rig.hibernation.frozen.isEmpty)

        // Hidden under its new key: it freezes again, and the quit's collection thaws it.
        advance(rig, seconds: 31)
        #expect(control.frozen, "the page never froze again under its new key")
        #expect(rig.hibernation.frozen == ["tab_real"])
        rig.hibernation.holdAwake(true)
        #expect(!control.frozen, "the quit's collection did not reach the rekeyed page")
        rig.hibernation.holdAwake(false)
        #expect(control.frozen)
    }

    /// Its workspace hibernates right after the rekey, with no plan between: the release asks the
    /// page what it holds, so the page thaws first even though its frozen entry has the old key.
    @Test func aRekeyedFrozenChatThawsBeforeItsWorkspaceReleasesIt() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        let view = try rig.hiddenChat("tab_provisional", session: "s-rekey-release")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_provisional"))
        #expect(control.frozen)
        rig.records["tab_real"] = rig.records["tab_provisional"]
        rig.tabs.rekey("tab_provisional", to: "tab_real")
        rig.tabs.aliases["tab_provisional"] = nil
        #expect(rig.tabs.existingView("tab_real") === view)
        #expect(rig.hibernation.releaseForWorkspace("tab_real") == nil)
        #expect(!control.frozen, "the rekeyed page was asked for its state while frozen")
        #expect(rig.hibernation.frozen.isEmpty)
    }

    /// The provisional key still resolves (its alias stays until the tree drops it), so the page is
    /// under both keys. While its workspace release under the real key asks it for its state, a plan
    /// must not freeze it again under the provisional key.
    @Test func aPageBeingReleasedUnderOneKeyDoesNotFreezeUnderTheOther() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        rig.hibernation.wakeState = { _ in try? await Task.sleep(for: .seconds(30)); return nil }
        _ = try rig.hiddenChat("tab_provisional", session: "s-both")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_provisional"))
        #expect(control.frozen)
        rig.records["tab_real"] = rig.records["tab_provisional"]
        rig.tabs.rekey("tab_provisional", to: "tab_real")
        #expect(rig.hibernation.releaseForWorkspace("tab_real") == nil)
        #expect(!control.frozen)
        advance(rig, seconds: 60)
        #expect(!control.frozen, "a plan froze the page again while its release asked it for its state")
        #expect(control.calls == [true, false], "\(control.calls)")
    }

    /// Rekeyed with its alias kept, the page is under both keys and both age past the threshold.
    /// Work for it thaws it, and the plan that follows must not freeze it again under the other key.
    @Test func workForAPageUnderTwoKeysDoesNotRefreezeItUnderTheOther() throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        rig.hibernation.isRendering = { rig.rendering.contains($0) }
        let view = try rig.hiddenChat("tab_provisional", session: "s-two-keys")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_provisional"))
        #expect(control.frozen)
        rig.records["tab_real"] = rig.records["tab_provisional"]
        rig.tabs.rekey("tab_provisional", to: "tab_real")
        // The alias stays: both keys show the page, and the real key's hidden clock starts.
        advance(rig, seconds: 1)
        #expect(control.frozen)
        advance(rig, seconds: 31)
        #expect(control.calls == [true], "the page was frozen twice: \(control.calls)")
        let wake = try #require(view.model.transport.beforePageWork, "the page lost its wake")
        wake()
        #expect(!control.frozen, "work for the page found it frozen again under its other key")
        advance(rig, seconds: 20)
        #expect(!control.frozen, "froze again before freezeHiddenTabs after the work")
        advance(rig, seconds: 11)
        #expect(control.frozen)
        #expect(control.calls == [true, false, true], "\(control.calls)")
    }

    /// Debug and automation actions call the page's scripts directly: a frozen page wakes first.
    @Test func aScriptCallOrPictureWakesAFrozenChat() async throws {
        let rig = Self.rig()
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        let view = try rig.hiddenChat("tab_script", session: "s-script")
        advance(rig, seconds: 31)
        let control = try #require(page(rig, "tab_script"))
        #expect(control.frozen)
        // The wake runs before the call starts (the test page never loads, so the call may not end).
        let call = Task { @MainActor in _ = try? await view.callPageScript("return 1;") }
        await rig.settle { !control.frozen }
        call.cancel()
        #expect(!control.frozen, "a script call reached a frozen page")
        advance(rig, seconds: 31)
        #expect(control.frozen)
        let picture = Task { @MainActor in _ = await view.pageSnapshot() }
        await rig.settle { !control.frozen }
        picture.cancel()
        #expect(!control.frozen, "a picture was asked of a frozen page")
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
