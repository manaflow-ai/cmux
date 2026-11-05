import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing
import CmuxNextTestSupport

/// `cmux browser <tab> upload` answers the page's own file chooser (`BrowserAgentFiles`). Before, an agent could
/// only put files into a visible `<input type=file>` it could select, through a page script with a 25 MB cap; a
/// button that opened a chooser (most upload widgets: a hidden input behind a styled button) left the agent at a
/// panel only the person could answer. The test drives the real WebKit entrypoint: the agent's script clicks a
/// hidden input with an agent gesture, as `AppBrowserPage.upload` does, WebKit calls the tab's
/// `runOpenPanelWith`, and the offered files reach the page without the person's picker being asked.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct WebKitTabAgentFilesTests {
    @MainActor private final class Answerer: WebFileInputAnswering {
        private(set) var asks = 0
        /// Runs at the next ask.
        var onAsk: (() -> Void)?

        func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                             completion: @escaping @MainActor ([URL]?) -> Void) {
            asks += 1
            completion(nil)
            onAsk?()
            onAsk = nil
        }
    }

    private struct Page {
        let tab: WebKitTab
        let window: NSWindow
        let engine: WebKitEngine

        func close() {
            window.close()
            tab.close()
        }
    }

    private func page(_ answerer: Answerer, input: String) async throws -> Page {
        let engine = WebKitEngine(fileInput: answerer, stores: .inMemory())  // the tab holds its engine weakly
        let tab = engine.makeWebKitTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.contentView
        _ = try await tab.callFunction("""
            const input = document.createElement("input");
            input.type = "file";
            input.id = "f";
            \(input)
            input.style.display = "none";
            (document.body || document.documentElement).appendChild(input);
            window.changed = new Promise((resolve) => input.addEventListener("change", resolve, { once: true }));
            return true;
            """, world: .page, gesture: .cmux)
        return Page(tab: tab, window: window, engine: engine)
    }

    private func files(_ names: [String]) throws -> (folder: URL, urls: [URL]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-agent-files-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls { try Data("cmux".utf8).write(to: url) }
        return (folder, urls)
    }

    @Test func anAgentsOfferAnswersAHiddenFileInputWithoutAskingThePerson() async throws {
        let (folder, offered) = try files(["report.csv", "photo.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let answerer = Answerer()
        let page = try await page(answerer, input: "input.multiple = true;")
        defer { page.close() }

        let outcome = try await page.tab.agentFiles.offer(offered, within: .seconds(10)) {
            _ = try await page.tab.evaluate("document.getElementById('f').click(); true", world: .page, gesture: .agent)
            return true
        }
        let picked = try await page.tab.callFunction("""
            await window.changed;
            return Array.from(document.getElementById("f").files, (file) => file.name);
            """, world: .page, gesture: .cmux)

        #expect(outcome == .chosen(offered), "the chooser answered \(outcome)")
        #expect(picked == .array([.string("report.csv"), .string("photo.png")]), "the page got \(picked)")
        #expect(answerer.asks == 0, "the person's picker was asked \(answerer.asks) times")
        #expect(!page.tab.agentFiles.isArmed, "the offer outlived its chooser")
    }

    @Test func aSingleFileInputRefusesSeveralFilesAndThePageGetsNone() async throws {
        let (folder, offered) = try files(["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let answerer = Answerer()
        let page = try await page(answerer, input: "")
        defer { page.close() }

        let outcome = try await page.tab.agentFiles.offer(offered, within: .seconds(10)) {
            _ = try await page.tab.evaluate("document.getElementById('f').click(); true", world: .page, gesture: .agent)
            return true
        }
        let count = try await page.tab.evaluate("document.getElementById('f').files.length", world: .page, gesture: .cmux)

        #expect(outcome == .refused(.tooManyFiles), "the chooser answered \(outcome)")
        #expect(count == .number(0), "the page got \(count) files")
        #expect(answerer.asks == 0, "the person's picker was asked for an agent's chooser")
    }

    @Test func anOfferNoChooserTakesIsWithdrawnAndTheNextChooserAsksThePerson() async throws {
        let (folder, offered) = try files(["a.txt"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let answerer = Answerer()
        let page = try await page(answerer, input: "")
        defer { page.close() }

        // The open step found nothing to click: the offer ends at once, not at its limit.
        let outcome = try await page.tab.agentFiles.offer(offered, within: .seconds(30)) { false }
        await withCheckedContinuation { (asked: CheckedContinuation<Void, Never>) in
            answerer.onAsk = { asked.resume() }
            Task { _ = try? await page.tab.evaluate("document.getElementById('f').click(); true", world: .page, gesture: .agent) }
        }

        #expect(outcome == .withdrawn)
        #expect(answerer.asks == 1, "a chooser after the offer ended did not ask the person")
    }
}
