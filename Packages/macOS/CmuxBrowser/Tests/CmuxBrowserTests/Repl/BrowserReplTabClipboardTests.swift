import Testing

@testable import CmuxBrowser

/// A tab's virtual clipboard (`page.clipboard`, Meta+C, Meta+X and Meta+V,
/// and the page's own Clipboard API in a tab a session created) belongs to
/// the session that created the tab, while it lives. No other session reads
/// or writes it, a user's tab has none, and nothing started under one
/// creator lands after it left.
@Suite("Browser REPL tab clipboard")
struct BrowserReplTabClipboardTests {
    @Test func onlyTheLiveCreatorReadsAndWritesIt() {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        let wrote = clipboard.write(["secret"], by: "creator")
        #expect(wrote)
        #expect(clipboard.read(by: "creator") == ["secret"])
        #expect(clipboard.read(by: "other") == nil, "another session reads nothing")
        let planted = clipboard.write(["planted"], by: "other")
        #expect(!planted, "and writes nothing")
        #expect(clipboard.read(by: "creator") == ["secret"])
    }

    // A user's tab, also one a finished run kept, has no clipboard for
    // sessions: two sessions driving it must not pass bytes through it.
    @Test func aUsersTabHasNoSessionClipboard() {
        var clipboard = BrowserReplTabClipboard<String>()
        let wrote = clipboard.write(["a's bytes"], by: "a")
        #expect(!wrote)
        #expect(clipboard.read(by: "a") == nil)
        #expect(clipboard.read(by: "b") == nil)
        let pageWrote = clipboard.writeFromPage(["page bytes"])
        #expect(!pageWrote, "a page write has nowhere to land")
    }

    @Test func itEmptiesWhenTheCreatorLeaves() {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        clipboard.write(["secret"], by: "creator")
        clipboard.setOwner(nil)
        #expect(clipboard.read(by: "creator") == nil)
        // A page script of the kept tab writes after its creator left; a
        // later session that creates nothing here never reads it.
        let pageWrote = clipboard.writeFromPage(["page bytes"])
        #expect(!pageWrote)
        clipboard.setOwner("later")
        #expect(clipboard.read(by: "later") == [], "a new tenure starts empty")
    }

    @Test func thePagesWritesLandOnlyWhileASessionOwnsTheTab() {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        let pageWrote = clipboard.writeFromPage(["copied by the page"])
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
        let afterLeaving = clipboard.store(["late copy"], during: tenure)
        #expect(!afterLeaving)
        clipboard.setOwner("creator")
        let inLaterTenure = clipboard.store(["late copy"], during: tenure)
        #expect(!inLaterTenure, "not in a later tenure either")
        #expect(clipboard.read(by: "creator") == [])
        let current = try #require(clipboard.tenure)
        let stored = clipboard.store(["copy"], during: current)
        #expect(stored)
        #expect(clipboard.read(by: "creator") == ["copy"])
    }

    @Test func settingTheSameOwnerKeepsTheClipboard() {
        var clipboard = BrowserReplTabClipboard<String>()
        clipboard.setOwner("creator")
        clipboard.write(["kept"], by: "creator")
        clipboard.setOwner("creator")
        #expect(clipboard.read(by: "creator") == ["kept"])
    }
}
