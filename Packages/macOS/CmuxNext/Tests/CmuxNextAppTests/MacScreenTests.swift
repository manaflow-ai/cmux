import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import CmuxNextSettings
import CmuxNextWakeups
import CmuxScreenKit
import CmuxTheme
import Foundation
import Testing

nonisolated private let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

/// A counter shared with a Sendable closure (tests).
nonisolated private final class Locked<Value: Sendable>: @unchecked Sendable {
    // @unchecked: `stored` is behind `lock`.
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

/// A store in a fresh temporary folder.
private func makeStore(removeLinkPairings: @escaping @Sendable () -> Void = {}) -> (MacScreenStore, URL) {
    let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
    return (MacScreenStore(file: file, removeLinkPairings: removeLinkPairings), file)
}

/// A device's screen pane, not asking the hub.
@MainActor
private func devicePane(_ name: String = "Studio") -> MacScreenPane {
    MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: deviceID) { nil }, name: name, preferences: ScreenPreferences())
}

/// Mac Screen tabs: the record, scrolling.
struct MacScreenRecordTests {
    @Test func homeRecordRoundTrips() throws {
        #expect(MacScreenRecord.homeURL.absoluteString == "cmux://mac-screen")
        #expect(try #require(MacScreenRecord(url: MacScreenRecord.homeURL)).isHome)
        #expect(MacScreenRecord.matches(URL(string: "CMUX://Mac-Screen?device=x")))
    }

    @Test func otherAddressesAreNotRecords() {
        #expect(MacScreenRecord(url: URL(string: "cmux://remote-view?host=mock")!) == nil)
        #expect(!MacScreenRecord.matches(URL(string: "https://mac-screen.example")))
    }

    /// An old link record still parses (a restored tab says links are gone).
    @Test func oldLinkRecordsParseAsLegacy() throws {
        let id = UUID()
        let parsed = try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?mac=\(id.uuidString)")!))
        #expect(parsed.macID == id && parsed.deviceID == nil && !parsed.isHome)
        #expect(try #require(MacScreenRecord(url: URL(string: "cmux://mac-screen?mac=not-a-uuid")!)).isHome)
    }
}

/// Link pairing is gone: the store keeps only device names, and its first
/// load removes the old link pairings (Keychain items) once.
@MainActor
struct MacScreenStoreTests {
    /// A file from a build with link pairing: the cleanup runs once, the old fields go.
    @Test func theFirstLoadRemovesLinkPairingsOnce() async throws {
        let removed = Locked(0)
        let (store, file) = makeStore { removed.set(removed.value + 1) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"macs":[{"id":"7A235AB3-718A-4CDE-B720-35F643A6B6D5","name":"Studio","addedAt":0,"preferences":{}}],"shareEnabled":true,"hubDeviceName":"Office"}"#
        try Data(old.utf8).write(to: file)
        await store.load()
        await store.flush()
        #expect(removed.value == 1)
        #expect(store.hubDeviceName == "Office")
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("macs") && !saved.contains("shareEnabled") && saved.contains("linkPairingsRemoved"))
        // A later launch does not run it again.
        let (again, _) = (MacScreenStore(file: file, removeLinkPairings: { removed.set(removed.value + 1) }), file)
        await again.load()
        #expect(removed.value == 1)
        #expect(again.hubDeviceName == "Office")
    }

    @Test func deviceNamesAndThisMacsNamePersist() async throws {
        let (store, file) = makeStore()
        await store.load()
        store.setHubDeviceName("  Office  ")
        #expect(store.rememberDeviceNames([deviceID: "Mac mini 2"]))
        #expect(!store.rememberDeviceNames([deviceID: "Mac mini 2"]))
        await store.flush()
        let reloaded = MacScreenStore(file: file)
        await reloaded.load()
        #expect(reloaded.hubDeviceName == "Office" && reloaded.deviceNames[deviceID] == "Mac mini 2")
    }
}

/// A pairing link pasted or typed in an address bar is refused with a word,
/// and never searched (it carried a room secret).
struct MacScreenAddressTests {
    @Test(arguments: [
        "cmux-vnc://pair?signal=https://s.example&room=00112233445566778899aabbccddeeff&secret=abcdefghijklmnopqrstuvwxyzABCDEF0123&name=Mac",
        "cmux://mac-screen",
        "cmux://mac-screen?device=\(deviceID)",
    ])
    func macScreenAddressesNeverSearch(_ text: String) {
        let url = BrowserURLResolver().url(for: text)
        #expect(url?.absoluteString == text)
        #expect(!OmniboxRemoteSuggestions.allows(text, resolver: OmniboxResolver()))
    }

    @MainActor
    @Test func aPastedPairingLinkIsRefusedWithAWord() throws {
        let link = try #require(BrowserURLResolver().url(for: "cmux-vnc://pair?room=aa&secret=bb&name=Mac"))
        let refusal = try #require(MacScreenPages.pairingLinkRefusal(for: link.absoluteString))
        #expect(refusal.contains("Settings"))
        #expect(MacScreenPages.pairingLinkRefusal(for: MacScreenRecord.homeURL.absoluteString) == nil)
        #expect(MacScreenPages.pairingLinkRefusal(for: "https://example.com") == nil)
        // A search for text that holds one (the address bar's other way to send it out).
        #expect(MacScreenPages.pairingLinkRefusal(for: "https://www.google.com/search?q=hi%20cmux-vnc%3A%2F%2Fpair%3Froom%3Dr") != nil)
    }

    /// H7 walkthrough: the New Tab field offered "Search the web for cmux-vnc://pair?…" and
    /// Return asked Codex. The New Tab paths (the page's rows, `newTab.submit` from the CLI,
    /// MCP and palette) never search, ask an agent with, or load pairing-link text.
    @Test(arguments: [
        "cmux-vnc://pair?room=h7dummyroom0000&secret=h7dummysecret0000",
        "  CMUX-VNC://pair?room=r&secret=s  ",
        "cmux-vnc:pair?room=r&secret=s",
        "connect to cmux-vnc://pair?room=r&secret=s please",
    ])
    func newTabNeverSearchesAsksOrLoadsAPairingLink(_ text: String) {
        for search in [false, true] {
            let plan = NewTabSubmit.plan(text: text, search: search, agent: "codex", resolver: OmniboxResolver(), home: nil)
            switch plan {
            case .browser, .chat: Issue.record("\(text.debugDescription) search=\(search) planned \(plan)")
            default: break
            }
        }
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

/// Mac Screen is its own page tab kind (`InternalPageID.macScreen`), not a
/// browser page: its route names only the record ("home", "device:<id>"), and
/// a tab restored on an old link record says links are no longer supported.
@MainActor
struct MacScreenPageTabTests {
    private func makePages() -> MacScreenPages {
        MacScreenPages(store: makeStore().0, work: BackgroundWork())
    }

    /// Makes `key`'s view and waits until its screen (or home page) is in.
    private func show(_ key: String, in pages: MacScreenPages) async throws -> MacScreenTab {
        _ = pages.makeView(for: key)
        let tab = try #require(pages.tab(key))
        await tab.loading?.value
        return tab
    }

    /// A tab restored on an old `mac=` link record shows the not-supported card, with Close Tab.
    @Test func aRestoredLinkTabSaysLinksAreGone() async throws {
        let pages = makePages()
        var closed: [String] = []
        pages.events.closeTab = { closed.append($0) }
        pages.restore("mac:\(UUID().uuidString)", for: "old")
        let tab = try await show("old", in: pages)
        let pane = try #require(tab.pane)
        #expect(pane.model.gate == .unsupported && pane.model.card == .unsupported)
        #expect(pane.session == nil && !pane.view.input.controlMode)
        pane.view.chrome.actions.closeTab()
        #expect(closed == ["old"])
        #expect(pages.title(for: "old") == MacScreenPages.homeTitle)
        pages.tabClosed("old")
    }

    @Test func homeTabAndUnknownRoutesShowTheHomePage() async throws {
        let pages = makePages()
        pages.restore("not a route", for: "odd")
        let tab = try await show("odd", in: pages)
        #expect(tab.record == MacScreenRecord(macID: nil))
        #expect(tab.pane == nil)
        #expect(pages.title(for: "odd") == "Mac Screen")
        pages.tabClosed("odd")
    }

    /// Home on a device's tab replaces it with a home tab (its route becomes "home").
    @Test func homeFromADeviceTabReplacesIt() async throws {
        let pages = makePages()
        var replaced: [(MacScreenRecord, String)] = []
        pages.events.replaceTab = { record, key in
            replaced.append((record, key))
            return true
        }
        pages.prepare("device", record: MacScreenRecord(deviceID: deviceID), byPerson: true)
        let tab = try await show("device", in: pages)
        tab.pane?.handlers.openHome()
        #expect(replaced.map(\.0) == [MacScreenRecord(macID: nil)])
        #expect(replaced.map(\.1) == ["device"])
        pages.tabClosed("device")
    }

    /// The tab's content view takes the keyboard for its screen's input surface.
    @Test func focusGoesToTheInputSurface() async throws {
        let pages = makePages()
        pages.prepare("tab", record: MacScreenRecord(deviceID: deviceID), byPerson: true)
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

    /// Without a device hub (or signed out) the home page says how to set Mac Screen up.
    @Test func theHomePageExplainsTheSetup() {
        #expect(MacScreenHomeSnapshot.setupNote(configured: false) != MacScreenHomeSnapshot.setupNote(configured: true))
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

        let pages = MacScreenPages(store: makeStore().0, work: BackgroundWork())
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        root.addSubview(tab)
        let home = try #require(tab.subviews.first as? MacScreenHomeView)
        let pane = devicePane("Theme Test")
        root.addSubview(pane.view)
        let hosts: [MacScreenThemedView] = [home, pane.view.chrome.toolbar, pane.view.chrome.card]

        let darkInk = try rgb(MacScreenColors.resolved(in: root).primary)
        for host in hosts {
            #expect(try rgb(host.colors.primary) == darkInk)
            #expect(try rgb(host.colors.page) == rgb(MacScreenColors.resolved(in: host).page))
            #expect(host.colors.isDark)
        }
        try paint(scope, background: 0xF7F3E8, foreground: 0x1D1A14)
        let lightInk = try rgb(MacScreenColors.resolved(in: root).primary)
        #expect(lightInk != darkInk)
        for host in hosts {
            // Live: the theme change reached every surface without a new view.
            #expect(try rgb(host.colors.primary) == lightInk)
            #expect(try rgb(host.colors.chrome) == rgb(MacScreenColors.resolved(in: host).chrome))
            #expect(!host.colors.isDark)
        }
        pane.close()
        pages.tabClosed("home")
    }

    /// A color's sRGB components, rounded (to compare colors made apart).
    private func rgb(_ color: NSColor) throws -> [Int] {
        let srgb = try #require(color.usingColorSpace(.sRGB))
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Int(($0 * 255).rounded()) }
    }
}

/// A stalled connection shows Reconnecting at once, not a frozen picture.
@MainActor
struct MacScreenPaneConnectTests {
    @Test func aStalledStreamShowsReconnecting() {
        #expect(MacScreenPaneModel.connectedCard(hasFrame: true, stalled: false) == nil)
        #expect(MacScreenPaneModel.connectedCard(hasFrame: true, stalled: true) == .connecting(reconnecting: true))
        #expect(MacScreenPaneModel.connectedCard(hasFrame: false, stalled: false) == .waitingForPicture)
    }
}

/// The connecting card says "Reconnecting…" only after the tab has shown the Mac once.
struct MacScreenConnectingCardTests {
    @Test func firstConnectSaysConnecting() {
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: true, everConnected: false) == .connecting(reconnecting: false))
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: false, everConnected: false) == .connecting(reconnecting: false))
    }

    @Test func aDroppedStreamSaysReconnecting() {
        #expect(MacScreenPaneModel.connectingCard(isReconnecting: true, everConnected: true) == .connecting(reconnecting: true))
    }
}

/// A Mac screen never takes the keyboard until the person clicks the picture.
@MainActor
struct MacScreenOpenKeyboardTests {
    @Test func aNewScreenStartsReleased() {
        let pane = devicePane("Keys")
        #expect(pane.view.input.isReleased)
        #expect(!pane.model.capturesKeyboard)
        pane.close()
    }
}

/// The screen takes input only while it is live with no card.
@MainActor
struct MacScreenCardInputTests {
    @Test func onlyALiveScreenWithNoCardTakesInput() {
        #expect(MacScreenPaneView.takesInput(gate: .open, card: nil))
        for card: MacScreenCard in [.connecting(reconnecting: false), .connecting(reconnecting: true), .waitingForPicture, .failed, .ended,
                                    .hubConnect] {
            #expect(!MacScreenPaneView.takesInput(gate: .open, card: card))
        }
        #expect(!MacScreenPaneView.takesInput(gate: .unsupported, card: .unsupported))
    }

    @Test func aClickBesideACardNeverReachesTheCaptureView() throws {
        let pane = devicePane("Card")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        pane.view.frame = root.bounds
        root.addSubview(pane.view)
        root.layoutSubtreeIfNeeded()
        // Not connected: the Connect card shows over the screen.
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

/// 120 Hz streaming: the pane tells its session how fast its display
/// refreshes, and the stats line shows the agreed rate next to the measured one.
@MainActor
struct MacScreenFrameRateTests {
    @Test func thePaneReportsItsDisplayRateToTheSession() {
        let pane = devicePane()
        #expect(pane.session?.displayMaximumFrameRate == nil, "nothing reported before the pane is in a window")
        pane.view.reportDisplayRefresh(120)
        #expect(pane.session?.displayMaximumFrameRate == 120)
        // The window moved to a 60 Hz display.
        pane.view.reportDisplayRefresh(60)
        #expect(pane.session?.displayMaximumFrameRate == 60)
        // No screen (the window left every display): the last rate stays.
        pane.view.reportDisplayRefresh(nil)
        #expect(pane.session?.displayMaximumFrameRate == 60)
    }

    #if DEBUG
    /// DEV builds (`debug.mac_screen` `display_fps`): a pane on a 60 Hz
    /// display can report 120, to check the 120 fps path end to end.
    @Test func aDevOverrideIsReportedInsteadOfTheDisplaysRate() {
        let pane = devicePane()
        pane.view.reportDisplayRefresh(60)
        pane.view.debugDisplayFrameRate = 120
        #expect(pane.session?.displayMaximumFrameRate == 120, "the override is reported at once")
        pane.view.reportDisplayRefresh(60)
        #expect(pane.session?.displayMaximumFrameRate == 120, "the display's own rate does not replace it")
        pane.view.debugDisplayFrameRate = nil
        pane.view.reportDisplayRefresh(60)
        #expect(pane.session?.displayMaximumFrameRate == 60, "with the override off the display's rate counts again")
    }
    #endif

    @Test func statsShowTheAgreedRateNextToTheMeasuredOne() {
        let agreed = MacScreenToolbarView.statsLine(path: "Direct", fps: 118.4, targetFps: 120, latencyMs: 4, encoding: "H264 HW",
                                                frameSize: CGSize(width: 3024, height: 1964))
        #expect(agreed == "Direct · 118/120 fps · 4 ms · H264 HW · 3024×1964")
        // A host that predates the agreed rate sends none: the line is as before.
        let oldHost = MacScreenToolbarView.statsLine(path: "Relay", fps: 59.6, targetFps: nil, latencyMs: nil, encoding: "-", frameSize: .zero)
        #expect(oldHost == "Relay · 60 fps")
    }
}
