import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// A click on an attachment in Home opens it in cmux (the host), never in Finder or another app,
/// and its right-click menu is the host's file menu (Lawrence 2026-10-20: "for chief if i click on
/// an image of html etc it should open to the right instead of finder, but i should be able to
/// right click, open with other app").
@MainActor @Suite struct HomeFileHostTests {
    final class Host: HomeFileHost {
        var opened: [URL] = []
        var menuNames: [String] = []
        func open(_ file: URL) { opened.append(file) }
        func menuItems(forFileNamed name: String, resolve: @escaping @MainActor () async -> URL?) -> [NSMenuItem] {
            menuNames.append(name)
            return [NSMenuItem(title: "Open in Right Pane", action: nil, keyEquivalent: ""),
                    NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")]
        }
    }

    private static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-file-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anAttachmentOpensInTheHost() throws {
        let host = Host()
        let file = try Self.temp().appendingPathComponent("index.html")
        try Data("<p>hi</p>".utf8).write(to: file)
        HomeAttachmentOpen.open(file, host: host)
        #expect(host.opened == [file])
    }

    @Test func theMenuIsTheHostsFileMenu() {
        let host = Host()
        let items = HomeAttachmentOpen.menuItems(name: "index.html", host: host, resolve: { nil }, fallback: {})
        #expect(items.map(\.title) == ["Open in Right Pane", "Open With"])
        #expect(host.menuNames == ["index.html"])
    }

    @Test func withoutAHostTheMenuKeepsOpenInDefaultApp() {
        let items = HomeAttachmentOpen.menuItems(name: "index.html", host: nil, resolve: { nil }, fallback: {})
        #expect(items.count == 1)
        #expect(items.first?.title == CmuxStrings.openInDefaultApp)
    }

    @Test func aFetchedCopyGetsTheAttachmentsName() throws {
        // The store's copy is named by its hash; cmux picks the viewer (and Open With its apps)
        // from the name, and a page finds its siblings by name.
        let dir = try Self.temp()
        let blob = dir.appendingPathComponent("3f9a0c")
        try Data("<p>hi</p>".utf8).write(to: blob)
        let named = try HomeAttachmentOpen.named(blob, name: "index.html", hash: "3f9a0c", in: dir.appendingPathComponent("named"))
        #expect(named.lastPathComponent == "index.html")
        #expect(try Data(contentsOf: named) == Data("<p>hi</p>".utf8))
        // A copy that already has the name is used as it is.
        #expect(try HomeAttachmentOpen.named(named, name: "index.html", hash: "3f9a0c", in: dir) == named)
        // A second call reuses the first copy.
        #expect(try HomeAttachmentOpen.named(blob, name: "index.html", hash: "3f9a0c", in: dir.appendingPathComponent("named")) == named)
    }

    @Test func aNameCannotLeaveTheFolder() throws {
        let dir = try Self.temp()
        let blob = dir.appendingPathComponent("abc")
        try Data("x".utf8).write(to: blob)
        let named = try HomeAttachmentOpen.named(blob, name: "../../etc/passwd", hash: "abc", in: dir.appendingPathComponent("named"))
        #expect(named.deletingLastPathComponent().deletingLastPathComponent() == dir.appendingPathComponent("named"))
        #expect(named.lastPathComponent == "passwd")
    }
}
