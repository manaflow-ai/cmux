import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// hq#1925 bug 2: a person opens a local page, follows two links to its sibling pages, quits and
/// reopens cmux. The page comes back with its saved Back entries, so Back (Cmd-[) takes it to the
/// page before, as it does for a web page. Runs a real WebKit tab in a window, restored the way the
/// app restores a browser tab after a relaunch: the page loads, then its saved entries come back.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct BrowserRestoredFileHistoryTests {
    @Test func backAfterARelaunchReturnsToTheLocalPageBefore() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-filehist-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func page(_ name: String, next: String?) throws -> URL {
            let url = folder.appendingPathComponent("\(name).html")
            let link = next.map { "<a id='next' href='\($0).html'>next</a>" } ?? ""
            try "<!doctype html><title>\(name)</title><p>\(name)</p>\(link)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let a = try page("a", next: "b"), b = try page("b", next: "c"), c = try page("c", next: nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = WebKitEngine().makeWebKitTab()
        window.contentView = tab.contentView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
            tab.close()
        }

        let deadline = ContinuousClock.now + .seconds(20)
        func until(_ done: () -> Bool) async {
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func shown() -> String? { tab.state.url?.standardizedFileURL.lastPathComponent }

        tab.load(c)
        tab.restoreSession([BrowserSavedEntry(url: a, title: "a"), BrowserSavedEntry(url: b, title: "b"),
                            BrowserSavedEntry(url: c, title: "c")], current: 2)
        await until { shown() == "c.html" && tab.state.canGoBack }
        #expect(tab.state.canGoBack, "Back is greyed on a restored local page that had two pages before it")

        tab.goBack()
        await until { shown() == "b.html" }
        #expect(shown() == "b.html")
        await until { tab.state.canGoBack && !tab.restored.isStepping }
        tab.goBack()
        await until { shown() == "a.html" }
        #expect(shown() == "a.html")
    }
}
