import Foundation
import Testing

@testable import CmuxBrowser

/// `secrets.load` loads every entry or none: an entry it refuses after
/// others were valid (a value that is not a string, a bad domain pattern) leaves the store as it was, so the session can give the
/// file's protection back without leaving part of the file registered.
@Suite("Browser REPL secrets.load atomicity")
struct BrowserReplSecretLoadAtomicityTests {
    @Test func aLoadThatRefusesALaterEntryRegistersNothing() throws {
        let store = BrowserReplSecretStore()
        #expect(throws: BrowserReplDriverError.self) {
            try store.load([
                "a.example.com": ["first": "Zx9-strong-VALUE-77"],
                "b.example.com": ["second": 42],
            ])
        }
        #expect(!store.has("first"), "an entry before the refused one stayed registered")
        #expect(store.isEmpty)
    }

    @Test func aRefusedLoadKeepsTheEarlierValueOfANameItReplaces() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "first", value: "Old-strong-VALUE-11", domains: ["a.example.com"], totp: false, title: "secrets.set")
        #expect(throws: BrowserReplDriverError.self) {
            try store.load([
                "a.example.com": ["first": "New-strong-VALUE-22"],
                "b.example.com": ["second": ["value": "Zx9-strong-VALUE-77", "totp": true]],
            ])
        }
        let masked = store.captureMasks.map(\.value)
        #expect(masked == ["Old-strong-VALUE-11"], "the refused load changed the store: \(masked.count) masks")
    }
}
