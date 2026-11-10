import AppKit
import CmuxNextBookmarks
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation
import Testing

/// The Bookmarks page shows the daemon's rows, and the app keeps no tree that could lag them:
/// `open`, `openAll` and `icons` read the rows they act on from the daemon (through the host), and a
/// daemon that cannot answer is the page's `unavailable`.
@MainActor @Suite
struct BookmarkPageHostTests {
    /// The workspace a top page's window shows, as the app's observable state.
    @MainActor @Observable final class Workspace {
        var profile = "a"
    }

    struct Down: Error {}

    @MainActor final class Host: BookmarkPageHost {
        /// The daemon's rows.
        var rows: [BookmarkNode] = []
        var down = false
        var reads = 0
        var opened: [String] = []
        func bookmarkProfile(ofTab key: String) -> String { "default" }
        func bookmarkRows(_ ids: [String], profile: String) async throws -> [BookmarkNode] {
            reads += 1
            if down { throw Down() }
            return ids.compactMap { id in rows.first { $0.id == id } }
        }

        func bookmarkChildren(of id: String, profile: String) async throws -> [BookmarkNode] {
            reads += 1
            if down { throw Down() }
            return rows.filter { $0.parent == id }
        }

        var bookmarkFolderIconsSupported: Bool { false }
        func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage? { nil }
        func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage? {
            node.icon == nil ? nil : NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in true }
        }

        var bookmarkIconRevision: Int { 0 }
        func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String) {
            opened.append(node.url?.absoluteString ?? node.id)
        }
    }

    static func rows(_ url: String) throws -> [BookmarkNode] {
        [BookmarkNode(id: "bm_folder", parent: BookmarkRoot.bar.rawValue, kind: .folder, title: "Work"),
         BookmarkNode(id: "bm_docs", parent: "bm_folder", kind: .url, title: "Docs", url: try #require(URL(string: url)))]
    }

    let context = PageCallContext(page: PageDescriptor.bookmarks.id)
    /// A call right after the person's click or key `n` in the page view.
    func clicked(_ n: TimeInterval) -> PageCallContext {
        PageCallContext(page: PageDescriptor.bookmarks.id, userGesture: true, gestureEvent: n)
    }

    /// The row is read from the daemon on each open: a URL changed elsewhere opens the new one,
    /// whatever the page sent.
    @Test func openReadsTheDaemonsRow() async throws {
        let host = Host()
        host.rows = try Self.rows("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_docs", "url": "https://old.example/"], context: clicked(1))
        #expect(host.opened == ["https://new.example/"])
        #expect(host.reads == 1)
        // A folder or a row gone is not opened.
        await #expect(throws: PageError.self) {
            _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_folder"], context: clicked(2))
        }
        await #expect(throws: PageError.self) {
            _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_gone"], context: clicked(3))
        }
        #expect(host.opened.count == 1)
    }

    @Test func openAllReadsTheFolderFromTheDaemon() async throws {
        let host = Host()
        host.rows = try Self.rows("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        _ = try await page.call("cmux.bookmarkPage.openAll", params: ["folder": "bm_folder"], context: clicked(4))
        #expect(host.opened == ["https://new.example/"])
    }

    /// The icons of the rows on screen: a folder with an icon gets its image, one without and an
    /// unknown id get none; a daemon that cannot answer is `unavailable`.
    @Test func iconsReadTheRowsOnScreenFromTheDaemon() async throws {
        let host = Host()
        var rows = try Self.rows("https://new.example/")
        rows.append(BookmarkNode(id: "bm_emoji", parent: BookmarkRoot.bar.rawValue, kind: .folder, title: "Rocket", icon: "🚀"))
        host.rows = rows
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        let ids: [CmuxNextSettings.JSONValue] = [.string("bm_emoji"), .string("bm_folder"), .string("bm_gone")]
        let reply = try await page.call("cmux.bookmarkPage.icons", params: .object(["ids": .array(ids)]), context: context)
        let icons = reply["icons"]?.objectValue ?? [:]
        #expect(icons["bm_emoji"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
        #expect(icons["bm_folder"] == nil && icons["bm_gone"] == nil)
        host.down = true
        await #expect {
            _ = try await page.call("cmux.bookmarkPage.icons", params: .object(["ids": .array(ids)]), context: context)
        } throws: { ($0 as? PageError)?.code == "cmux.bookmarkPage.unavailable" }
    }

    @Test func aTopPageReReadsItsStateWhenItsWindowsProfileChanges() async throws {
        let host = Host()
        let workspace = Workspace()
        let page = BookmarkPageHostProvider(host: host, tabKey: "top")
        page.profileOverride = { workspace.profile }
        let state = try await page.call("cmux.bookmarkPage.state", params: .object([:]), context: context)
        #expect(state["browser_profile_id"]?.stringValue == "a")
        let (reasons, sink) = AsyncStream.makeStream(of: String.self)
        let subscription = try await page.subscribe(BookmarkPageHostProvider.changedStream, filter: .null, context: context) { event in
            sink.yield(event["reason"]?.stringValue ?? "")
        }
        defer { subscription.cancel() }
        // The window moves to a workspace of another profile; the page is never hidden and shown.
        workspace.profile = "b"
        var iterator = reasons.makeAsyncIterator()
        #expect(await iterator.next() == "state")
    }

    @Test func pageScriptAloneOpensNothing() async throws {
        let host = Host()
        host.rows = try Self.rows("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        for (op, params) in [("cmux.bookmarkPage.open", ["bookmark": "bm_docs"] as CmuxNextSettings.JSONValue),
                             ("cmux.bookmarkPage.openAll", ["folder": "bm_folder"])] {
            await #expect(throws: PageError.self) { _ = try await page.call(op, params: params, context: context) }
        }
        #expect(host.opened.isEmpty)
        #expect(host.reads == 0)
    }

    @Test func oneClickOpensOnce() async throws {
        let host = Host()
        host.rows = try Self.rows("https://new.example/")
        let page = BookmarkPageHostProvider(host: host, tabKey: "t")
        let click = clicked(42)
        _ = try await page.call("cmux.bookmarkPage.open", params: ["bookmark": "bm_docs"], context: click)
        await #expect(throws: PageError.self) {
            _ = try await page.call("cmux.bookmarkPage.openAll", params: ["folder": "bm_folder"], context: click)
        }
        #expect(host.opened == ["https://new.example/"])
    }
}
