import AppKit
@testable import CmuxNextMacScreen
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

    @Test func addsAStreamLinkAndKeepsTheSecretOutOfTheFile() throws {
        let (store, file, secrets) = makeStore()
        let pairing = link()
        let mac = try store.add(link: pairing.link.absoluteString).get()
        #expect(mac.name == "Studio")
        #expect(secrets.pairing(for: mac.id.uuidString) == pairing)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains(pairing.secret))
        #expect(!saved.contains(pairing.room))
        let reloaded = MacScreenStore(file: file, secrets: secrets)
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

    @Test func refusesThisMacsOwnLink() {
        let (store, _, _) = makeStore()
        let own = store.hostPairing(name: "This Mac")
        #expect(store.add(link: own.link.absoluteString) == .failure(.ownLink))
    }

    @Test func forgetRemovesTheSecret() throws {
        let (store, _, secrets) = makeStore()
        let mac = try store.add(link: link().link.absoluteString).get()
        store.forget(mac.id)
        #expect(store.macs.isEmpty)
        #expect(secrets.pairing(for: mac.id.uuidString) == nil)
    }

    @Test func hostPairingIsStableUntilReset() {
        let (store, file, secrets) = makeStore()
        let first = store.hostPairing(name: "Mac A")
        #expect(first.isStream)
        #expect(store.hostPairing(name: "Mac A") == first)
        let renamed = store.hostPairing(name: "Mac B")
        #expect(renamed.room == first.room && renamed.name == "Mac B")
        let reset = store.resetHostPairing(name: "Mac B")
        #expect(reset.room != first.room && reset.secret != first.secret)
        store.setShareEnabled(true)
        #expect(MacScreenStore(file: file, secrets: secrets).shareEnabled)
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
