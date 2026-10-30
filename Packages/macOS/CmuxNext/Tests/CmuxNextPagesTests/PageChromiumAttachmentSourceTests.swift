@testable import CmuxNextPages
import AppKit
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A Chromium page reports the person's drop, paste and file-input pick to its host as a WebKit page
/// does (``PageWebView/onFilesDropped``, ``PageWebView/onPaste``, ``PageWebView/onFilesChosen``):
/// the agent chat records where those files came from (`AgentPaneDroppedPaths`).
@MainActor
struct PageChromiumAttachmentSourceTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.attachment-source", resource: "attachment-source", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-attachment-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func started(_ hosting: FakeChromiumHosting, chooses: Bool = false) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        if chooses { view.onFilesChosen = { _ in } }
        await view.chromiumStart?.value
        return (view, try #require(hosting.made.first))
    }

    /// The page's drop reports the files of the real drag that entered it, once; a drop message with
    /// no drag (page script can post one) reports nothing.
    @Test func aDropReportsTheFilesOfTheDragThatEntered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        var dropped: [[URL]] = []
        let files = [URL(fileURLWithPath: "/tmp/shot.png"), URL(fileURLWithPath: "/tmp/notes.txt")]
        let drop = FakeChromiumPage.bindingCall(["name": PageChromiumDocumentScripts.pageDropHandler, "body": [String: String]()])
        page.onEvent?(.filesDragged(files))
        let first: [URL]? = await PageTestWait.value("drop") { done in
            view.onFilesDropped = { dropped.append($0); done($0) }
            page.onEvent?(.devTools(drop))
        }
        #expect(first == files)
        // Once: a second message, and one with no drag the host saw, report nothing.
        view.onFilesDropped = { dropped.append($0) }
        page.onEvent?(.devTools(drop))
        await Self.settle(view, page)
        #expect(dropped == [files])
        view.close()
    }

    /// Cmd-V in the page (the shim's key event) is the paste the host hears, through one entry.
    @Test func aPasteInThePageReachesTheHost() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        var pastes = 0
        view.onPaste = { pastes += 1 }
        page.onEvent?(.pasted)
        #expect(pastes == 1)
        // Our menu's Paste and the menu bar's go through the same entry.
        view.chromiumPasted()
        #expect(pastes == 2)
        view.close()
    }

    /// Only a page that records the pick takes its file choosers from Chromium; every other page
    /// keeps Chromium's own panel (and its accept filters).
    @Test func onlyAPageThatRecordsThePickAnswersItsChooser() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = FakeChromiumHosting()
        let (other, otherPage) = try await started(plain)
        #expect(otherPage.answersFileChooser == false)
        other.close()

        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting, chooses: true)
        #expect(page.answersFileChooser == true)
        var chosen: [URL] = []
        view.onFilesChosen = { chosen = $0 }
        page.onEvent?(.filesChosen([URL(fileURLWithPath: "/tmp/download.pdf")]))
        #expect(chosen == [URL(fileURLWithPath: "/tmp/download.pdf")])
        view.onFilesChosen = nil
        #expect(page.answersFileChooser == false)
        view.close()
    }

    /// Returns once the page's messages sent so far reached the host (they are handled in order).
    private static func settle(_ view: PageWebView, _ page: FakeChromiumPage) async {
        let opened: URL? = await PageTestWait.value("settle") { done in
            view.onOpenExternal = { done($0) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall([
                "name": PageChromiumDocumentScripts.navigateHandler, "body": ["url": "https://example.com/settle"],
            ])))
        }
        view.onOpenExternal = nil
        #expect(opened == URL(string: "https://example.com/settle"))
    }
}
