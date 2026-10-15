import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextMacScreen
import CmuxNextRemoteView
import CmuxNextSettings
import CmuxScreenKit
import Foundation
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

    @Test func noInputBehindTheConfirmCardUntilConnect() {
        let pane = MacScreenPane(name: "Gate Test", pairing: pairing(), preferences: ScreenPreferences(), confirmed: false)
        #expect(pane.model.gate == .confirm)
        #expect(!pane.view.input.controlMode)
        #expect(!pane.model.capturesKeyboard)
        // What Connect does to the input (no network here: the session is not started).
        pane.model.gate = .open
        pane.view.syncInputGate()
        #expect(pane.view.input.controlMode)
        // Not in a window, so not first responder: the state says so.
        #expect(pane.model.capturesKeyboard == pane.view.input.hasKeyboard)
        pane.close()
    }

    @Test func forgottenMacStopsInput() {
        let pane = MacScreenPane(name: "Gate Test", pairing: pairing(), preferences: ScreenPreferences(), confirmed: true)
        #expect(pane.view.input.controlMode)
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
