import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The toolbar's Downloads popup content is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): no
/// SwiftUI bridge; it lists the downloads newest first, follows the list (a new row, a status
/// change, Clear coming and going), and its footer runs Show in Folder and Clear.
@MainActor @Suite(.serialized)
struct BrowserDownloadsPopupViewTests {
    private static func subviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    private static func rows(_ root: NSView) -> [NSView] {
        subviews(of: root).filter { $0.accessibilityIdentifier() == "browser.downloads.row" && !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func find(_ id: String, in root: NSView) -> NSView? {
        subviews(of: root).first { $0.accessibilityIdentifier() == id && !$0.isHiddenOrHasHiddenAncestor }
    }

    @Test func theContentFollowsTheListAndItsFooterRuns() throws {
        _ = NSApplication.shared
        let list = BrowserDownloadList()
        let model = BrowserDownloadsPopupModel()
        model.list = list
        var folders = 0
        model.onShowFolder = { folders += 1 }
        let view = BrowserDownloadsPopupView(model: model)
        view.reload()
        #expect(!hostsSwiftUI(view))
        #expect(view.accessibilityIdentifier() == "browser.downloads.popup")
        #expect(Self.find("browser.downloads.empty", in: view) != nil)
        #expect(Self.rows(view).isEmpty)
        #expect(Self.find("browser.downloads.clear", in: view) == nil, "nothing ended: no Clear")

        let file = FileManager.default.temporaryDirectory.appending(path: "a-\(UUID().uuidString).pdf")
        list.add(.ended(sourceURL: URL(string: "https://example.com/a.pdf"), filename: "a.pdf", destination: file,
                        status: .finished, receivedBytes: 1, totalBytes: 1), tab: "t") { _ in }
        let running = BrowserDownload(sourceURL: URL(string: "https://example.com/b.zip"), filename: "b.zip")
        list.add(running, tab: "t") { _ in }
        view.reload()
        #expect(Self.find("browser.downloads.empty", in: view) == nil)
        #expect(Self.rows(view).map { $0.accessibilityLabel() ?? "" }.map { $0.hasPrefix("b.zip") } == [true, false], "newest first")
        #expect(Self.find("browser.downloads.clear", in: view) != nil)

        let folder = try #require(Self.find("browser.downloads.showFolder", in: view) as? NSButton)
        folder.performClick(nil)
        #expect(folders == 1)
        let clear = try #require(Self.find("browser.downloads.clear", in: view) as? NSButton)
        clear.performClick(nil)
        view.reload()
        #expect(Self.rows(view).count == 1, "Clear removes the ended download, the running one stays")
    }
}

/// Whether `root`'s own view tree (not the inside of an AppKit control, whose private views on
/// macOS 26 include hosting views of AppKit's own) holds a SwiftUI hosting bridge.
@MainActor
private func hostsSwiftUI(_ root: NSView) -> Bool {
    if String(describing: type(of: root)).contains("Hosting") { return true }
    if root is NSControl { return false }
    return root.subviews.contains { hostsSwiftUI($0) }
}
