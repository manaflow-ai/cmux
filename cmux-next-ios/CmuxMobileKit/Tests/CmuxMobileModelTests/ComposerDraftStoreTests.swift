import Foundation
import Testing
@testable import CmuxMobileModel

/// A composer draft is kept on disk by Mac and tab until its send empties it.
@MainActor
@Suite struct ComposerDraftStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "composer-drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "drafts.json")
    }

    @Test func aDraftSurvivesTheAppRestarting() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = ComposerDraftStore.key(macID: "cosmic", tabID: "s7")
        let first = ComposerDraftStore(url: url)
        first.save("git status && make te", for: key)
        // The app goes to the background (or is killed after it): the write goes at once.
        first.flush()
        let relaunched = ComposerDraftStore(url: url)
        #expect(relaunched.text(for: key) == "git status && make te")
        // The same tab id on another Mac is another tab.
        #expect(relaunched.text(for: ComposerDraftStore.key(macID: "mini", tabID: "s7")) == nil)
    }

    @Test func anEmptiedComposerRemovesItsDraft() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = ComposerDraftStore.key(macID: "cosmic", tabID: "s7")
        let store = ComposerDraftStore(url: url)
        store.save("ls", for: key)
        store.save("", for: key)
        store.flush()
        #expect(ComposerDraftStore(url: url).text(for: key) == nil)
    }

    @Test func oldAndExtraDraftsGo() {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = ComposerDraftStore(url: nil, now: { clock })
        for index in 0..<(ComposerDraftStore.limit + 5) {
            clock += 1
            store.save("draft \(index)", for: "m|s\(index)")
        }
        #expect(store.text(for: "m|s0") == nil, "the oldest go past the limit")
        #expect(store.text(for: "m|s\(ComposerDraftStore.limit + 4)") == "draft \(ComposerDraftStore.limit + 4)")

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var then = Date(timeIntervalSince1970: 2_000_000)
        let early = ComposerDraftStore(url: url, now: { then })
        early.save("stale", for: "m|s1")
        early.flush()
        then += ComposerDraftStore.maxAge + 1
        #expect(ComposerDraftStore(url: url, now: { then }).text(for: "m|s1") == nil, "a closed tab's id is reused later")
    }
}
