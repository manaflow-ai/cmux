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
        func menuItems(forFileNamed name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem] {
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
        // MenuAction draws its icon with the app's appearance.
        _ = NSApplication.shared
        let items = HomeAttachmentOpen.menuItems(name: "index.html", host: nil, resolve: { nil }, fallback: {})
        #expect(items.count == 1)
        #expect((items.first as? MenuAction)?.label == CmuxStrings.openInDefaultApp)
    }

    @Test func withAHostTheClickSkipsTheAppLinkOpener() throws {
        let host = Host()
        var linked: [URL] = []
        let file = try Self.temp().appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: file)
        HomeAttachmentOpen.open(file, host: host, appLink: { linked.append($0) })
        #expect(host.opened == [file])
        #expect(linked.isEmpty)
        HomeAttachmentOpen.open(file, host: nil, appLink: { linked.append($0) })
        #expect(linked == [file])
    }
}
