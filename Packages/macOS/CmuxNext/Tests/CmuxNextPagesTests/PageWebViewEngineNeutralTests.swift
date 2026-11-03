import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// The calls a host makes on a page whichever engine shows it (``PageWebView`` in Chromium mode, with
/// a fake Chromium host): a picture, an extra message handler, and a right-click menu that waits for
/// the page's report.
@MainActor
struct PageWebViewEngineNeutralTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.engine-neutral", resource: "engine-neutral", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-neutral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func started(_ hosting: FakeChromiumHosting, before: (PageWebView) -> Void = { _ in }) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        before(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.showsChromium)
        return (view, page)
    }

    /// A script called while the Chromium page is still being made runs in Chromium once it is there,
    /// never in the hidden WebKit view that never loads the document (a cold chat's first
    /// `debug.agent_pane` call waited 5 s there for a hook that never came, cmuxterm-hq#6338).
    @Test func aScriptCalledWhileChromiumStartsRunsInChromium() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.onMade = { page in
            page.answer = { method, params in
                guard method == "Runtime.evaluate", (params["expression"] as? String)?.contains("return 7;") == true else { return nil }
                return #"{"result":{"type":"number","value":7}}"#
            }
        }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        #expect(!view.showsChromium, "the Chromium page was there before the call: nothing to wait for")
        let value = try await view.callPageScript("return 7;")
        let page = try #require(hosting.made.first)
        #expect(view.showsChromium)
        #expect(page.calls.contains { $0.method == "Runtime.evaluate" && (($0.params["expression"] as? String)?.contains("return 7;") ?? false) },
                "the call ran in the hidden WebKit view instead of the Chromium page")
        #expect((value as? NSNumber)?.intValue == 7)
        view.close()
    }

    /// A Chromium page that is never made does not hold a script call for good: once the wait runs
    /// out the call returns nil, and it never ran in the hidden WebKit view (cmux#34154).
    @Test(.timeLimit(.minutes(1))) func aScriptCallReturnsNilWhenTheChromiumStartNeverEnds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.hangs = true
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.immediate
        let value = try await view.callPageScript("return 7;")
        #expect(value == nil)
        #expect(!view.showsChromium)
        #expect(view.chromiumStart != nil, "the start ended: the call did not wait on a start in flight")
        view.close()
    }

    @Test func aPictureOfTheChromiumPageIsItsScreenshot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        view.frame = NSRect(x: 0, y: 0, width: 4, height: 3)
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(png.base64EncodedString())"}"# : nil }
        let snapshot = await view.snapshot()
        #expect(snapshot?.size == NSSize(width: 4, height: 3))
        view.close()
    }

    @Test func anExtraMessageHandlerHearsTheChromiumPage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        var heard: [String] = []
        let (view, page) = try await started(hosting) { view in
            view.addMessageHandler("testReport") { body in heard.append((body as? [String: Any])?["text"] as? String ?? "?") }
        }
        // The page script installs `window.webkit.messageHandlers.testReport`.
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            (($0.params["source"] as? String)?.contains("\"testReport\"") ?? false) })
        let got: String? = await PageTestWait.value("report") { done in
            view.addMessageHandler("testReport") { body in done((body as? [String: Any])?["text"] as? String ?? "?") }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": "testReport", "body": ["text": "hi"]])))
        }
        #expect(got == "hi")
        #expect(heard.isEmpty)
        view.close()
    }

    /// A host whose menu depends on the page's report (the agent chat) builds it only after its wait.
    @Test func aRightClickMenuWaitsForTheHostsWait() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        var built = 0
        view.contextMenuEditor = { menu in
            built += 1
            menu.addItem(PageWebView.menuItem("Row \(built)") {})
        }
        var waitedBeforeBuilding = false
        view.chromiumMenuWait = { waitedBeforeBuilding = built == 0 }
        var shown: [String]?
        var finished = false
        view.chromiumMenuPresenter = { menu, _, _ in
            // After the wait (a main-actor Task) the menu still tracks from a run-loop callout: a
            // menu tracking inside that Task's job held the main queue until it closed, and the
            // click that closed it waited on everything queued meanwhile (Leo, 2026-10-29).
            #expect(PageMenuCallout.isRunLoopBlock, "the menu tracked inside a main-queue job")
            shown = menu.items.map(\.title)
        }
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "", isEditable: false) { finished = true }))
        // The menu waits first: nothing is built in the click's own turn.
        #expect(built == 0)
        await PageMenuCallout.drain { finished }
        #expect(waitedBeforeBuilding)
        #expect(shown == ["Row 1"])
        #expect(finished, "Chromium never heard the menu closed")
        view.close()
    }
}
