import Foundation
import Testing

@testable import CmuxBrowser

/// A tab's virtual clipboard (`page.clipboard`, Meta+C, Meta+X and Meta+V,
/// and the page's own Clipboard API in a tab a session created) belongs to
/// the session that created the tab, while it lives. No other session reads
/// or writes it, a user's tab has none, and nothing started under one
/// creator lands after it left.
@Suite("Browser REPL tab clipboard")
struct BrowserReplTabClipboardTests {
    @Test func onlyTheLiveCreatorReadsAndWritesIt() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        let wrote = try clipboard.write(["secret"], by: "creator")
        #expect(wrote)
        #expect(clipboard.read(by: "creator") == ["secret"])
        #expect(clipboard.read(by: "other") == nil, "another session reads nothing")
        let planted = try clipboard.write(["planted"], by: "other")
        #expect(!planted, "and writes nothing")
        #expect(clipboard.read(by: "creator") == ["secret"])
    }

    // A user's tab, also one a finished run kept, has no clipboard for
    // sessions: two sessions driving it must not pass bytes through it.
    @Test func aUsersTabHasNoSessionClipboard() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        let wrote = try clipboard.write(["a's bytes"], by: "a")
        #expect(!wrote)
        #expect(clipboard.read(by: "a") == nil)
        #expect(clipboard.read(by: "b") == nil)
        let pageWrote = try clipboard.writeFromPage(["page bytes"])
        #expect(!pageWrote, "a page write has nowhere to land")
    }

    @Test func itEmptiesWhenTheCreatorLeaves() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        try clipboard.write(["secret"], by: "creator")
        clipboard.setOwner(nil)
        #expect(clipboard.read(by: "creator") == nil)
        // A page script of the kept tab writes after its creator left; a
        // later session that creates nothing here never reads it.
        let pageWrote = try clipboard.writeFromPage(["page bytes"])
        #expect(!pageWrote)
        clipboard.setOwner("later")
        #expect(clipboard.read(by: "later") == [], "a new tenure starts empty")
    }

    @Test func thePagesWritesLandOnlyWhileASessionOwnsTheTab() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        let pageWrote = try clipboard.writeFromPage(["copied by the page"])
        #expect(pageWrote)
        #expect(clipboard.read(by: "creator") == ["copied by the page"])
    }

    // Copy and Cut take what the page put on the clipboard once WebKit's
    // command finishes; a creator that left meanwhile must not have its
    // tab's clipboard filled again for whoever drives the tab next.
    @Test func aCopyStartedUnderOneCreatorNeverLandsAfterIt() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        let tenure = try #require(clipboard.tenure)
        clipboard.setOwner(nil)
        let afterLeaving = try clipboard.store(["late copy"], during: tenure)
        #expect(!afterLeaving)
        clipboard.setOwner("creator")
        let inLaterTenure = try clipboard.store(["late copy"], during: tenure)
        #expect(!inLaterTenure, "not in a later tenure either")
        #expect(clipboard.read(by: "creator") == [])
        let current = try #require(clipboard.tenure)
        let stored = try clipboard.store(["copy"], during: current)
        #expect(stored)
        #expect(clipboard.read(by: "creator") == ["copy"])
    }

    @Test func settingTheSameOwnerKeepsTheClipboard() throws {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        try clipboard.write(["kept"], by: "creator")
        clipboard.setOwner("creator")
        #expect(clipboard.read(by: "creator") == ["kept"])
    }

    private static func item(_ text: String, type: String = "text/plain") -> [String: Any] {
        ["type": type, "base64": Data(text.utf8).base64EncodedString()]
    }

    private static func pageClipboard() -> BrowserReplTabClipboard<[String: Any]> {
        BrowserReplTabClipboard(measure: BrowserReplPageClipboard.bytes(of:))
    }

    /// r25 tabs#2: the agent's `clipboard.write` takes the same validator
    /// as the page's writes (``BrowserReplPageClipboard/items(from:)``): at
    /// most 32 typed items with Base64 data, 64 MiB of it in all.
    @Test func anAgentWriteTakesThePageClipboardsLimits() throws {
        var clipboard = Self.pageClipboard()
        clipboard.setOwner("creator")
        let tooMany = (0..<33).map { _ in Self.item("a") }
        let refused: [[String: Any]] = [
            ["items": tooMany],
            ["items": [["type": "text/plain", "base64": "not base64!"]]],
            ["items": [["type": "no type", "base64": ""]]],
            ["items": [["type": "text/plain"]]],
            ["items": "text"],
        ]
        for message in refused {
            #expect(throws: BrowserReplDriverError.self, "\(message)") { try clipboard.write(message: message, by: "creator") }
        }
        #expect(clipboard.read(by: "creator")?.isEmpty == true, "nothing refused was stored")
        let wrote = try clipboard.write(message: ["items": Array(tooMany.dropLast())], by: "creator")
        #expect(wrote)
        #expect(clipboard.read(by: "creator")?.count == 32)
        #expect(try clipboard.write(message: ["items": [Self.item("x")]], by: "other") == false)
    }

    /// r25 tabs#2: what a tab's clipboard holds is the owning session's
    /// memory, in its ledger, until it is replaced, emptied or dropped.
    @Test func theClipboardIsChargedToTheOwnersLedger() throws {
        let ledger = BrowserReplResourceLedger(limits: .standard.with(.clipboardBytes, 64))
        let one = Self.item("abc")
        let oneBytes = BrowserReplPageClipboard.bytes(of: one)
        do {
            var clipboard = Self.pageClipboard()
            clipboard.setOwner("creator", ledger: ledger)
            try clipboard.write(message: ["items": [one]], by: "creator")
            #expect(ledger.held(.clipboardBytes) == oneBytes)
            #expect(ledger.held(.sessionMemoryBytes) == oneBytes)

            // Past the ledger's limit: refused, the earlier items kept.
            #expect(throws: BrowserReplDriverError.self) {
                try clipboard.write(message: ["items": [Self.item(String(repeating: "x", count: 100))]], by: "creator")
            }
            #expect(throws: BrowserReplResourceLimitError.self) {
                try clipboard.writeFromPage([Self.item(String(repeating: "y", count: 100))])
            }
            #expect(clipboard.read(by: "creator")?.count == 1)
            #expect(ledger.held(.clipboardBytes) == oneBytes)

            // Replaced: charged at the new size.
            let two = [Self.item("de"), Self.item("f")]
            try clipboard.writeFromPage(two)
            #expect(ledger.held(.clipboardBytes) == two.map(BrowserReplPageClipboard.bytes(of:)).reduce(0, +))
            let tenure = try #require(clipboard.tenure)
            try clipboard.store([one], during: tenure)
            #expect(ledger.held(.clipboardBytes) == oneBytes)

            // Emptied when the owner leaves.
            clipboard.setOwner(nil)
            #expect(ledger.held(.clipboardBytes) == 0)
            clipboard.setOwner("creator", ledger: ledger)
            try clipboard.write(message: ["items": [one]], by: "creator")
            #expect(ledger.held(.clipboardBytes) == oneBytes)
        }
        // Dropped with its tab.
        #expect(ledger.outstanding.isEmpty, "\(ledger.outstanding)")
    }
}
