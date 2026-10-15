import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import CmuxNextSettings
import CmuxScreenKit
import CmuxTheme
import Foundation
import SwiftUI
import Testing

/// Mac Screen tabs: the record, the saved Macs and their secrets, scrolling.
struct MacScreenRecordTests {
    @Test func homeAndMacRecordsRoundTrip() throws {
        #expect(MacScreenRecord.homeURL.absoluteString == "cmux://mac-screen")
        let id = UUID()
        let record = MacScreenRecord(macID: id)
        let parsed = try #require(MacScreenRecord(url: record.url))
        #expect(parsed.macID == id)
        #expect(MacScreenRecord.matches(URL(string: "CMUX://Mac-Screen?mac=x")))
    }

    @Test func otherAddressesAreNotRecords() {
        #expect(MacScreenRecord(url: URL(string: "cmux://remote-view?host=mock")!) == nil)
        #expect(!MacScreenRecord.matches(URL(string: "https://mac-screen.example")))
    }

    @Test func malformedMacOpensHome() throws {
        let parsed = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?mac=not-a-uuid")!))
        #expect(parsed.macID == nil)
    }

    /// The record never carries the pairing secret.
    @Test func recordHoldsNoSecret() {
        let record = MacScreenRecord(macID: UUID())
        #expect(!record.url.absoluteString.contains("secret"))
        #expect(!record.url.absoluteString.contains("room"))
    }
}

@MainActor
struct MacScreenStoreTests {
    private func makeStore() -> (MacScreenStore, URL, MemoryMacScreenSecrets) {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let secrets = MemoryMacScreenSecrets()
        return (MacScreenStore(file: file, secrets: secrets), file, secrets)
    }

    private func link(name: String = "Studio", kind: String = "stream") -> VNCPairing {
        VNCPairing.generate(name: name, kind: kind)
    }

    @Test func addsAStreamLinkAndKeepsTheSecretOutOfTheFile() async throws {
        let (store, file, secrets) = makeStore()
        let pairing = link()
        let mac = try store.add(link: pairing.link.absoluteString).get()
        #expect(mac.name == "Studio")
        #expect(secrets.pairing(for: mac.id.uuidString) == pairing)
        await store.flush()
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains(pairing.secret))
        #expect(!saved.contains(pairing.room))
        let reloaded = MacScreenStore(file: file, secrets: secrets)
        #expect(!reloaded.isLoaded && reloaded.macs.isEmpty)
        await reloaded.load()
        #expect(reloaded.isLoaded)
        #expect(reloaded.macs.map(\.id) == [mac.id])
        #expect(reloaded.pairing(for: mac.id) == pairing)
    }

    @Test func rejectsWhatIsNotAScreenStreamLink() {
        let (store, _, _) = makeStore()
        #expect(store.add(link: "https://example.com") == .failure(.notALink))
        #expect(store.add(link: "cmux-vnc://pair?room=zz") == .failure(.notALink))
        #expect(store.add(link: link(kind: "vnc").link.absoluteString) == .failure(.notAScreenStream))
        #expect(store.macs.isEmpty)
    }

    @Test func pairingTheSameRoomAgainUpdatesThatMac() throws {
        let (store, _, _) = makeStore()
        var pairing = link(name: "Old name")
        let first = try store.add(link: pairing.link.absoluteString).get()
        pairing.name = "New name"
        let second = try store.add(link: " \(pairing.link.absoluteString)\n").get()
        #expect(first.id == second.id)
        #expect(store.macs.count == 1)
        #expect(store.macs.first?.name == "New name")
    }

    @Test func refusesThisMacsOwnLink() throws {
        let (store, _, _) = makeStore()
        let own = try #require(store.hostPairing(name: "This Mac"))
        #expect(store.add(link: own.link.absoluteString) == .failure(.ownLink))
    }

    @Test func forgetRemovesTheSecret() throws {
        let (store, _, secrets) = makeStore()
        let mac = try store.add(link: link().link.absoluteString).get()
        var forgotten: [UUID] = []
        store.onForgotten = { forgotten.append($0) }
        store.forget(mac.id)
        // Open tabs of the Mac hear it and end their sessions (MacScreenPages).
        #expect(forgotten == [mac.id])
        #expect(store.macs.isEmpty)
        #expect(secrets.pairing(for: mac.id.uuidString) == nil)
    }

    @Test func hostPairingIsStableUntilReset() async throws {
        let (store, file, secrets) = makeStore()
        let first = try #require(store.hostPairing(name: "Mac A"))
        #expect(first.isStream)
        #expect(store.hostPairing(name: "Mac A") == first)
        let renamed = try #require(store.hostPairing(name: "Mac B"))
        #expect(renamed.room == first.room && renamed.name == "Mac B")
        let reset = try #require(store.resetHostPairing(name: "Mac B"))
        #expect(reset.room != first.room && reset.secret != first.secret)
        store.setShareEnabled(true)
        await store.flush()
        let reloaded = MacScreenStore(file: file, secrets: secrets)
        await reloaded.load()
        #expect(reloaded.shareEnabled)
    }
}

extension MacScreenStoreTests {
    /// A pairing whose secret the Keychain refused is not saved: no Mac that
    /// opens as "not paired", and the person is told why.
    @Test func refusedSecretWriteDoesNotSaveTheMac() throws {
        let (store, _, secrets) = makeStore()
        secrets.writesFail = true
        let link = VNCPairing.generate(name: "Mac B", kind: "stream").link.absoluteString
        #expect(store.add(link: link) == .failure(.secretNotSaved))
        #expect(store.macs.isEmpty)
    }

    /// A refused write of this Mac's new link gives no link (it would change on every launch).
    @Test func refusedHostSecretWriteGivesNoLink() {
        let (store, _, secrets) = makeStore()
        secrets.writesFail = true
        #expect(store.hostPairing(name: "Mac A") == nil)
    }

    /// A locked or denied Keychain never resets this Mac's link (that would unpair every device).
    @Test func unreadableKeychainKeepsTheLink() throws {
        let (store, _, secrets) = makeStore()
        let first = try #require(store.hostPairing(name: "Mac"))
        secrets.failing = ["host"]
        #expect(store.hostPairing(name: "Mac") == nil)
        secrets.failing = []
        #expect(store.hostPairing(name: "Mac") == first)
    }
}

/// A pairing link typed in the address bar is a URL, never a search: its room secret must not reach a search engine.
struct MacScreenAddressTests {
    @Test(arguments: [
        "cmux-vnc://pair?signal=https://s.example&room=00112233445566778899aabbccddeeff&secret=abcdefghijklmnopqrstuvwxyzABCDEF0123&name=Mac",
        "cmux://mac-screen",
        "cmux://mac-screen?mac=7A235AB3-718A-4CDE-B720-35F643A6B6D5",
    ])
    func macScreenAddressesResolveToURLs(_ text: String) {
        let url = BrowserURLResolver().url(for: text)
        #expect(url?.absoluteString == text)
        #expect(!OmniboxRemoteSuggestions.allows(text, resolver: OmniboxResolver()))
    }

    @Test(arguments: ["cmux-vnc://other", "cmux://history-elsewhere", "javascript:alert(1)"])
    func otherSchemesStillSearch(_ text: String) {
        #expect(BrowserURLResolver().url(for: text) == nil)
    }
}

struct MacScreenScrollTests {
    @Test func wheelLinesPassThrough() {
        var scroll = MacScreenScroll()
        #expect(scroll.add(dx: 0, dy: 300, precise: false) == (0, 3))
        #expect(scroll.add(dx: -100, dy: -100, precise: false) == (-1, -1))
    }

    @Test func trackpadPointsAccumulateIntoLines() {
        var scroll = MacScreenScroll()
        #expect(scroll.add(dx: 0, dy: 500, precise: true) == (0, 0))
        #expect(scroll.add(dx: 0, dy: 500, precise: true) == (0, 1))
        #expect(scroll.add(dx: 0, dy: 600, precise: true) == (0, 1))
    }
}

/// Settings > Development exists only in DEV builds: every route to it (section, focused key)
/// opens the default page elsewhere.
struct MacScreenDevelopmentSettingsRouteTests {
    @Test func developmentRoutesOnlyInDevBuilds() {
        #expect(SettingsWindowService.route(section: .development, setting: nil, devBuild: true) == "#/settings/development")
        #expect(SettingsWindowService.route(section: .development, setting: nil, devBuild: false) == nil)
        #expect(SettingsWindowService.route(section: nil, setting: "macScreen.debug.relayOnly", devBuild: true)
            == "#/settings/development?focus=macScreen.debug.relayOnly")
        #expect(SettingsWindowService.route(section: nil, setting: "macScreen.debug.relayOnly", devBuild: false) == nil)
        #expect(SettingsWindowService.route(section: .advanced, setting: nil, devBuild: false) == "#/settings/advanced")
    }
}

/// Behind the Connect (confirm) or not-paired card a tab sends no input to the other Mac, and
/// after Connect its keyboard state follows the surface's real focus (it was stuck at "not
/// captured" while keys went to the remote).
@MainActor
struct MacScreenInputGateTests {
    private func pairing() -> VNCPairing { VNCPairing.generate(name: "Gate Test", kind: "stream") }

    /// Connect opens the screen but leaves the keyboard here until a click on
    /// the picture, as after the release chord (the next keystrokes never
    /// reach the remote Mac unasked).
    @Test func connectWaitsForAClickBeforeTakingTheKeyboard() {
        let pane = MacScreenPane(name: "Gate Test", pairing: pairing(), preferences: ScreenPreferences(), confirmed: false)
        pane.connectSession = { _ in }
        pane.debugConfirm()
        #expect(pane.model.gate == .open)
        #expect(pane.view.input.isReleased)
        #expect(!pane.view.input.hasKeyboard)
        #expect(!pane.model.capturesKeyboard)
        pane.close()
    }

    @Test func noInputBehindTheConfirmCardUntilConnect() {
        let pane = MacScreenPane(name: "Gate Test", pairing: pairing(), preferences: ScreenPreferences(), confirmed: false)
        #expect(pane.model.gate == .confirm)
        #expect(!pane.view.input.controlMode)
        #expect(!pane.model.capturesKeyboard)
        // What Connect does to the input (no network here: the session is not started).
        pane.model.gate = .open
        pane.view.syncInputGate()
        // Open, but no picture yet: the connecting card shows and the screen takes no input
        // until it is live (MacScreenCardInputTests).
        #expect(pane.model.card != nil)
        #expect(pane.view.input.controlMode == MacScreenPaneView.takesInput(gate: pane.model.gate, card: pane.model.card))
        // Not in a window, so not first responder: the state says so.
        #expect(pane.model.capturesKeyboard == pane.view.input.hasKeyboard)
        pane.close()
    }

    @Test func forgottenMacStopsInput() {
        let pane = MacScreenPane(name: "Gate Test", pairing: pairing(), preferences: ScreenPreferences(), confirmed: true)
        #expect(pane.model.gate == .open)
        pane.forgotten()
        #expect(pane.model.gate == .missing)
        #expect(!pane.view.input.controlMode)
        #expect(!pane.model.capturesKeyboard)
    }
}

/// A right-click is a right-click whatever button number the event carries:
/// synthetic events (accessibility tools, automation) post `rightMouseDown`
/// with button number 0, which read as a left click on the remote Mac.
@MainActor
struct MacScreenRightClickTests {
    private func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func syntheticRightMouseDownIsTheRightButton() throws {
        #expect(RemoteMouseButton(event: try event(.rightMouseDown)) == .right)
        #expect(RemoteMouseButton(event: try event(.rightMouseUp)) == .right)
        #expect(RemoteMouseButton(event: try event(.leftMouseDown)) == .left)
    }
}

/// Which tabs reconnect when Relay Only changes: only a stream that is live
/// (shown, or hidden within its grace), or a shown tab whose last try failed.
/// A hidden tab that ended or failed stays down until it is shown.
@MainActor
struct MacScreenRelayChangeTests {
    @Test func liveStreamsReconnectShownOrHidden() {
        #expect(MacScreenPane.reconnectsOnRelayChange(streaming: true, failed: false, visible: true, gateOpen: true, stoppedByPerson: false))
        #expect(MacScreenPane.reconnectsOnRelayChange(streaming: true, failed: false, visible: false, gateOpen: true, stoppedByPerson: false))
    }

    @Test func aFailedTabRetriesOnlyWhenShown() {
        #expect(MacScreenPane.reconnectsOnRelayChange(streaming: false, failed: true, visible: true, gateOpen: true, stoppedByPerson: false))
        #expect(!MacScreenPane.reconnectsOnRelayChange(streaming: false, failed: true, visible: false, gateOpen: true, stoppedByPerson: false))
    }

    @Test func endedWaitingOrStoppedTabsOnlyTakeTheSetting() {
        #expect(!MacScreenPane.reconnectsOnRelayChange(streaming: false, failed: false, visible: true, gateOpen: true, stoppedByPerson: false))
        #expect(!MacScreenPane.reconnectsOnRelayChange(streaming: true, failed: false, visible: true, gateOpen: false, stoppedByPerson: false))
        #expect(!MacScreenPane.reconnectsOnRelayChange(streaming: true, failed: false, visible: true, gateOpen: true, stoppedByPerson: true))
    }
}

/// Mac Screen is its own page tab kind (`InternalPageID.macScreen`), not a
/// browser page: its route names only the record ("home", "mac:<id>"), a
/// restored tab rebuilds it and waits for Connect, and the title follows the Mac.
@MainActor
struct MacScreenPageTabTests {
    private func makePages() -> (MacScreenPages, MacScreenStore) {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let store = MacScreenStore(file: file, secrets: MemoryMacScreenSecrets())
        return (MacScreenPages(store: store), store)
    }

    /// Makes `key`'s view and waits until its screen (or home page) is in.
    private func show(_ key: String, in pages: MacScreenPages) async throws -> MacScreenTab {
        _ = pages.makeView(for: key)
        let tab = try #require(pages.tab(key))
        await tab.loading?.value
        return tab
    }

    @Test func routesNameTheRecordAndNeverTheSecret() throws {
        let (pages, store) = makePages()
        let pairing = VNCPairing.generate(name: "Studio", kind: "stream")
        let mac = try store.add(link: pairing.link.absoluteString).get()
        pages.prepare("home-tab", record: MacScreenRecord(macID: nil), byPerson: true)
        pages.prepare("mac-tab", record: MacScreenRecord(macID: mac.id), byPerson: true)
        #expect(pages.route(for: "home-tab") == "home")
        let route = try #require(pages.route(for: "mac-tab"))
        #expect(route == "mac:\(mac.id.uuidString)")
        #expect(!route.contains(pairing.secret) && !route.contains(pairing.room))
        #expect(MacScreenPages.record(route: route) == MacScreenRecord(macID: mac.id))
        #expect(MacScreenPages.record(route: "home") == MacScreenRecord(macID: nil))
        #expect(MacScreenPages.record(route: "mac:not-a-uuid") == nil)
        #expect(MacScreenPages.record(route: "/Users/someone") == nil)
    }

    /// A tab restored on its route (relaunch, Reopen Closed) shows that Mac
    /// behind the Connect card: only a person's open connects at once.
    @Test func restoredMacTabWaitsForConnect() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        pages.restore("mac:\(mac.id.uuidString)", for: "restored")
        let restored = try await show("restored", in: pages)
        #expect(restored.pane?.model.gate == .confirm)
        #expect(pages.title(for: "restored") == "Studio")
        pages.prepare("person", record: MacScreenRecord(macID: mac.id), byPerson: true)
        let opened = try await show("person", in: pages)
        #expect(opened.pane?.model.gate == .open)
        pages.tabClosed("restored")
        pages.tabClosed("person")
        #expect(pages.tab("restored") == nil && pages.tab("person") == nil)
    }

    @Test func restoredTabOfAForgottenMacSaysItIsNotPaired() async throws {
        let (pages, _) = makePages()
        pages.restore("mac:\(UUID().uuidString)", for: "gone")
        let tab = try await show("gone", in: pages)
        #expect(tab.pane?.model.gate == .missing)
        pages.tabClosed("gone")
    }

    @Test func homeTabAndUnknownRoutesShowTheHomePage() async throws {
        let (pages, _) = makePages()
        pages.restore("not a route", for: "odd")
        let tab = try await show("odd", in: pages)
        #expect(tab.record == MacScreenRecord(macID: nil))
        #expect(tab.pane == nil)
        #expect(pages.title(for: "odd") == "Mac Screen")
        pages.tabClosed("odd")
    }

    /// Renaming the Mac retitles its tab at once; forgetting it ends the tab's session.
    @Test func renameRetitlesAndForgetEndsTheTab() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        var retitled: [String] = []
        pages.events.titleChanged = { retitled.append($0) }
        pages.prepare("tab", record: MacScreenRecord(macID: mac.id), byPerson: true)
        let tab = try await show("tab", in: pages)
        store.rename(mac.id, to: "Office")
        #expect(pages.title(for: "tab") == "Office")
        #expect(retitled.contains("tab"))
        store.forget(mac.id)
        #expect(tab.pane?.model.gate == .missing)
        pages.tabClosed("tab")
    }

    /// Connect (or Pair and Connect) on the home page opens the Mac as a new tab that replaces the
    /// home tab, so the tab's route is the Mac's ("mac:<id>") and a relaunch shows the same Mac. It
    /// came back as the home page when the Mac was swapped into the home tab (route "home").
    @Test func homeConnectReplacesTheHomeTabWithTheMacsTab() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        var replaced: [(MacScreenRecord, String)] = []
        pages.events.replaceTab = { record, key in
            replaced.append((record, key))
            return true
        }
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: false)
        _ = try await show("home", in: pages)
        pages.openFromHome(mac.id, in: "home")
        #expect(replaced.map(\.0) == [MacScreenRecord(macID: mac.id)])
        #expect(replaced.map(\.1) == ["home"])
        // The home tab itself is untouched (it closes once the Mac's tab exists).
        #expect(pages.tab("home")?.record == MacScreenRecord(macID: nil))
        #expect(pages.route(for: "home") == "home")
        pages.tabClosed("home")
    }

    /// Home on a Mac's tab replaces it with a home tab the same way (its route becomes "home").
    @Test func homeFromAMacTabReplacesIt() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        var replaced: [(MacScreenRecord, String)] = []
        pages.events.replaceTab = { record, key in
            replaced.append((record, key))
            return true
        }
        pages.prepare("mac", record: MacScreenRecord(macID: mac.id), byPerson: true)
        let tab = try await show("mac", in: pages)
        tab.pane?.handlers.openHome()
        #expect(replaced.map(\.0) == [MacScreenRecord(macID: nil)])
        #expect(replaced.map(\.1) == ["mac"])
        #expect(pages.tab("mac")?.record == MacScreenRecord(macID: mac.id))
        pages.tabClosed("mac")
    }

    /// Without a host that can open tabs (no pane lists the tab), the home page shows the Mac in
    /// its own tab, confirmed by the person.
    @Test func homeConnectWithoutAHostShowsTheMacInThisTab() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        pages.prepare("tab", record: MacScreenRecord(macID: nil), byPerson: false)
        _ = try await show("tab", in: pages)
        pages.openFromHome(mac.id, in: "tab")
        let tab = try #require(pages.tab("tab"))
        await tab.loading?.value
        #expect(tab.record == MacScreenRecord(macID: mac.id))
        #expect(tab.pane?.model.gate == .open)
        pages.tabClosed("tab")
    }

    /// The tab's content view takes the keyboard for its screen's input surface.
    @Test func focusGoesToTheInputSurface() async throws {
        let (pages, store) = makePages()
        let mac = try store.add(link: VNCPairing.generate(name: "Studio", kind: "stream").link.absoluteString).get()
        pages.prepare("tab", record: MacScreenRecord(macID: mac.id), byPerson: true)
        let tab = try await show("tab", in: pages)
        let pane = try #require(tab.pane)
        #expect(tab.view.focusTarget === pane.focusTarget)
        pages.tabClosed("tab")
    }

    /// The tab is shown while its view is in a window and not hidden.
    @Test func visibilityFollowsTheView() throws {
        let view = MacScreenTabView()
        var seen: [Bool] = []
        view.onVisibilityChange = { seen.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [], backing: .buffered, defer: true)
        let parent = NSView(frame: window.contentLayoutRect)
        window.contentView = parent
        parent.addSubview(view)
        #expect(view.isShown)
        parent.isHidden = true
        #expect(!view.isShown)
        parent.isHidden = false
        #expect(view.isShown)
        view.removeFromSuperview()
        #expect(!view.isShown)
        #expect(seen == [true, false, true, false])
    }

    /// A cmux://mac-screen address is no browser page any more: the browser hands it to the page tab.
    @Test func macScreenAddressIsNotABrowserAppPage() {
        #expect(!TabContentCache.isAppPage(MacScreenRecord.homeURL))
    }
}

/// Every Mac Screen surface draws in its tab's theme scope and follows Settings > Appearance live
/// (it used system styling: `.bar`, control background, system status colors).
@MainActor @Suite(.serialized)
struct MacScreenThemeTests {
    private func paint(_ scope: ThemeScope, background: UInt32, foreground: UInt32) throws {
        let input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground))
        scope.setOverride(try #require(ThemeSpec("Mac Screen Room")), input: input, animated: false)
    }

    @Test func homeToolbarAndCardsFollowTheirScope() throws {
        let scope = ThemeScope(level: .room)
        try paint(scope, background: 0x2B1650, foreground: 0xF4E3FF)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        scope.root(root)

        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, secrets: MemoryMacScreenSecrets()))
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        root.addSubview(tab)
        let home = try #require(tab.subviews.first as? MacScreenHostingView<MacScreenHomeView>)
        let pane = MacScreenPane(name: "Theme Test", pairing: VNCPairing.generate(name: "Theme Test", kind: "stream"),
                                 preferences: ScreenPreferences(), confirmed: false)
        root.addSubview(pane.view)
        let hosts: [any MacScreenThemedHost] = [home, pane.view.chrome.toolbar, pane.view.chrome.card]

        let darkInk = try rgb(MacScreenColors.resolved(in: root).primary)
        for host in hosts {
            #expect(try rgb(host.resolvedColors.primary) == darkInk)
            #expect(try rgb(host.resolvedColors.page) == rgb(MacScreenColors.resolved(in: host.hostView).page))
            #expect(host.resolvedColors.isDark)
        }
        try paint(scope, background: 0xF7F3E8, foreground: 0x1D1A14)
        let lightInk = try rgb(MacScreenColors.resolved(in: root).primary)
        #expect(lightInk != darkInk)
        for host in hosts {
            // Live: the theme change reached every surface without a new view.
            #expect(try rgb(host.resolvedColors.primary) == lightInk)
            #expect(try rgb(host.resolvedColors.chrome) == rgb(MacScreenColors.resolved(in: host.hostView).chrome))
            #expect(!host.resolvedColors.isDark)
        }
        pane.close()
        pages.tabClosed("home")
    }

    /// A color's sRGB components, rounded (to compare colors made apart).
    private func rgb(_ color: Color) throws -> [Int] {
        let srgb = try #require(NSColor(color).usingColorSpace(.sRGB))
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Int(($0 * 255).rounded()) }
    }
}

/// The colors a Mac Screen hosting view resolved, whatever it hosts.
@MainActor
private protocol MacScreenThemedHost {
    var resolvedColors: MacScreenColors { get }
    var hostView: NSView { get }
}

extension MacScreenHostingView: MacScreenThemedHost {
    var resolvedColors: MacScreenColors { themeAppearance.colors }
    var hostView: NSView { self }
}

/// Every connect the pane starts (showing the tab, Connect on the card, the toolbar's Connect and
/// Try Again) uses the session's reconnect policy (retries with backoff): a single attempt failed
/// at once on a relay that needs a few tries, showing the failed card in half a second.
@MainActor
struct MacScreenPaneConnectTests {
    private func pane(confirmed: Bool) -> (MacScreenPane, () -> Int) {
        let pane = MacScreenPane(name: "Connect Test", pairing: VNCPairing.generate(name: "Connect Test", kind: "stream"),
                                 preferences: ScreenPreferences(), confirmed: confirmed)
        var starts = 0
        pane.connectSession = { _ in starts += 1 }
        return (pane, { starts })
    }

    @Test func showingTheTabConnectsThroughTheReconnectPolicy() {
        let (pane, starts) = pane(confirmed: true)
        pane.resume()
        #expect(starts() == 1)
        pane.close()
    }

    @Test func connectOnTheCardAndTheToolbarUseIt() {
        let (pane, starts) = pane(confirmed: false)
        pane.resume()
        #expect(starts() == 0)
        pane.view.chrome.actions.confirm()
        #expect(starts() == 1)
        pane.view.chrome.actions.connect()
        #expect(starts() == 2)
        pane.close()
    }

    @Test func aTabThePersonStoppedStaysStopped() {
        let (pane, starts) = pane(confirmed: true)
        pane.resume()
        pane.view.chrome.actions.disconnect()
        pane.pause()
        pane.resume()
        #expect(starts() == 1)
        pane.close()
    }
}

/// The connecting card says "Reconnecting…" only after the tab has shown
/// the Mac once: every connect retries now, so the session's reconnecting
/// flag is set on a first connect too.
struct MacScreenConnectingCardTests {
    @Test func firstConnectSaysConnecting() {
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: true, everConnected: false) == .connecting(reconnecting: false))
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: false, everConnected: false) == .connecting(reconnecting: false))
    }

    @Test func aDroppedStreamSaysReconnecting() {
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: true, everConnected: true) == .connecting(reconnecting: true))
    }
}

/// A Mac screen never takes the keyboard until the person clicks the picture: every newly made
/// screen starts released (only Connect on the card did; a home Connect, Open in New Tab or a
/// pasted link gave the other Mac the keyboard at once).
@MainActor
struct MacScreenOpenKeyboardTests {
    @Test func aConfirmedScreenStartsReleased() {
        let pane = MacScreenPane(name: "Keys", pairing: VNCPairing.generate(name: "Keys", kind: "stream"),
                                 preferences: ScreenPreferences(), confirmed: true)
        #expect(pane.view.input.isReleased)
        #expect(!pane.model.capturesKeyboard)
        pane.close()
    }

    @Test func aMacOpenedFromTheHomePageStartsReleased() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        let store = MacScreenStore(file: file, secrets: MemoryMacScreenSecrets())
        let pages = MacScreenPages(store: store)
        let mac = try store.add(link: VNCPairing.generate(name: "Keys", kind: "stream").link.absoluteString).get()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        _ = pages.makeView(for: "home")
        pages.openFromHome(mac.id, in: "home")
        let tab = try #require(pages.tab("home"))
        await tab.loading?.value
        let pane = try #require(tab.pane)
        #expect(pane.model.gate == .open)
        #expect(pane.view.input.isReleased)
        #expect(!pane.model.capturesKeyboard)
        pages.tabClosed("home")
    }
}

/// Hosts take one viewer and the newest wins: when a screen of a Mac starts connecting, every
/// other screen of that Mac that is connecting or connected ends its session, hidden (as if its
/// grace ran out) or shown (no ping-pong between two splits). A hidden tab inside its grace kept
/// reconnecting and the shown tab got no picture for 20 s.
@MainActor
struct MacScreenOneViewerTests {
    private let mac = UUID(), other = UUID()

    @Test func otherActiveScreensOfTheSameMacEnd() {
        let panes = [
            MacScreenPaneActivity(key: "new", mac: mac, active: false),
            MacScreenPaneActivity(key: "hidden", mac: mac, active: true),
            MacScreenPaneActivity(key: "shown", mac: mac, active: true),
            MacScreenPaneActivity(key: "ended", mac: mac, active: false),
            MacScreenPaneActivity(key: "otherMac", mac: other, active: true),
        ]
        #expect(MacScreenPages.sessionsToEnd(starting: "new", panes: panes) == ["hidden", "shown"])
    }

    @Test func anUnknownOrMissingScreenEndsNothing() {
        let panes = [MacScreenPaneActivity(key: "a", mac: mac, active: true)]
        #expect(MacScreenPages.sessionsToEnd(starting: "gone", panes: panes).isEmpty)
        #expect(MacScreenPages.sessionsToEnd(starting: "a", panes: panes).isEmpty)
    }

    /// The pane says when it starts a connect, before it starts it.
    @Test func thePaneAnnouncesItsConnects() {
        let pane = MacScreenPane(name: "One", pairing: VNCPairing.generate(name: "One", kind: "stream"),
                                 preferences: ScreenPreferences(), confirmed: true)
        var events: [String] = []
        pane.handlers.willConnect = { events.append("will") }
        pane.connectSession = { _ in events.append("connect") }
        pane.resume()
        pane.view.chrome.actions.connect()
        #expect(events == ["will", "connect", "will", "connect"])
        pane.close()
    }
}

/// The screen takes input only while it is live with no card. A card's button over the picture
/// (Try Again, Reconnect) sometimes also reached the capture view under it, which forwarded the
/// click to the other Mac and took the keyboard: the capture view stayed in control mode under
/// every card once the gate was open.
@MainActor
struct MacScreenCardInputTests {
    @Test func onlyALiveScreenWithNoCardTakesInput() {
        #expect(MacScreenPaneView.takesInput(gate: .open, card: nil))
        for card: MacScreenCard in [.connecting(reconnecting: false), .connecting(reconnecting: true), .waitingForPicture, .failed, .ended] {
            #expect(!MacScreenPaneView.takesInput(gate: .open, card: card))
        }
        #expect(!MacScreenPaneView.takesInput(gate: .confirm, card: .confirm))
        #expect(!MacScreenPaneView.takesInput(gate: .missing, card: .missing))
    }

    @Test func aClickBesideACardNeverReachesTheCaptureView() throws {
        let pane = MacScreenPane(name: "Card", pairing: VNCPairing.generate(name: "Card", kind: "stream"),
                                 preferences: ScreenPreferences(), confirmed: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        pane.view.frame = root.bounds
        root.addSubview(pane.view)
        root.layoutSubtreeIfNeeded()
        // No picture yet: a card shows over the screen.
        #expect(pane.model.card != nil)
        #expect(!pane.view.input.controlMode)
        #expect(!pane.view.input.acceptsPointer)
        let area = pane.view.screenRect
        for local in [CGPoint(x: area.minX + 8, y: area.maxY - 8), CGPoint(x: area.midX, y: area.midY)] {
            let hit = pane.view.hitTest(pane.view.convert(local, to: root))
            #expect(hit !== pane.view.capture)
        }
        #expect(!pane.model.capturesKeyboard)
        pane.close()
    }
}
