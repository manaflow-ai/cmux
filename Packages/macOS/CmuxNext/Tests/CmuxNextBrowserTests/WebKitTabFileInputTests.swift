import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing
import CmuxNextTestSupport

/// A WebKit browser tab's `<input type="file">` goes through the engine's one file-input path
/// (`WebKitEngine.fileInput`, in the app the made-ahead `MadeAheadOpenPanel`), as an agent composer page's does
/// (`PageOpenPanel`). The tab had its own copy of the handler that called `NSOpenPanel()` itself (deep review of
/// fleet-gui, finding 2): no panel made ahead (a cold 160 to 830 ms panel per click), and no dead-panel guard, so
/// with no view service the page's file input could wait forever on a sheet handler that never came. The shared path
/// removes that wait-forever (a dead panel ends the input as a cancel) and reuses a panel made ahead; it does not
/// remove the main-thread block of a click that has to make its panel (up to about 40 s with a hung or absent panel
/// service: `MadeAheadOpenPanel+WebFileInputAnswering`).
///
/// The test drives the real entrypoint: a page script clicks a file input (`callAsyncJavaScript` runs with a user
/// gesture), WebKit calls the tab's `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`, and the page
/// reads back the files it was given. The answerer stands in for the panel, which a test host cannot show.
///
/// The red, on a handler that makes its own panel, depends on the host and has not been observed yet: the answerer
/// is never asked, and the handler's `NSOpenPanel()` either shows a sheet that never ends (a console-user host: the
/// test fails at its time limit) or, with no view service, blocks the main thread on ViewBridge and may end the test
/// process (`OpenPanelWarmGate`), which then fails the whole CmuxNextBrowserTests run instead of this test. Unverified
/// premises of the green, to be recorded per macOS major on the fleet: that the script's user gesture lets
/// `input.click()` reach `runOpenPanelWith`, and that WebKit asks for a web view in a window never ordered on screen.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct WebKitTabFileInputTests {
    @MainActor private final class Answerer: WebFileInputAnswering {
        struct Ask {
            let allowsMultipleSelection: Bool
            let allowsDirectories: Bool
            let window: NSWindow?
        }
        private(set) var asks: [Ask] = []
        private let answer: [URL]

        init(answer: [URL]) {
            self.answer = answer
        }

        func answerFileInput(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?,
                             completion: @escaping @MainActor ([URL]?) -> Void) {
            asks.append(Ask(allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories,
                            window: window))
            completion(answer)
        }
    }

    @Test func aPageFileInputOnAWebKitTabIsAnsweredByTheEnginesSharedPathOnItsWindow() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-file-input-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chosen = [folder.appendingPathComponent("first.txt"), folder.appendingPathComponent("second.txt")]
        for file in chosen { try Data("cmux".utf8).write(to: file) }

        let answerer = Answerer(answer: chosen)
        let engine = WebKitEngine(fileInput: answerer, stores: .inMemory())  // the tab holds its engine weakly
        let page = engine.makeWebKitTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.contentView
        defer {
            window.close()
            page.close()
        }

        // One script: make the input, arm the wait for its change event, click it inside the script's user gesture,
        // and return the names of the files the page got.
        let picked = try await page.callFunction("""
            const input = document.createElement("input");
            input.type = "file";
            input.multiple = true;
            (document.body || document.documentElement).appendChild(input);
            const changed = new Promise((resolve) => input.addEventListener("change", resolve, { once: true }));
            input.click();
            await changed;
            return Array.from(input.files, (file) => file.name);
            """, world: .page, gesture: .agent)

        let ask = try #require(answerer.asks.first, "the tab's file input did not go through the engine's shared path")
        #expect(answerer.asks.count == 1, "one click asked the picker \(answerer.asks.count) times")
        #expect(ask.allowsMultipleSelection && !ask.allowsDirectories, "the input's choices did not reach the picker")
        #expect(ask.window === window, "the picker was not asked to show on the page's window")
        #expect(picked == .array([.string("first.txt"), .string("second.txt")]), "the page got \(picked)")
    }
}
