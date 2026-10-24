import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// Memory Saver keep rules the page's recorder answers (`BrowserPageBusy`), run in a real WebKit
/// page. Chrome never discards a tab connected to a USB or Bluetooth device
/// (kConnectedToUSB, kConnectedToBluetooth); cmux also keeps open HID and serial devices. A
/// Chromium cross-origin child frame gets no recorder, so the person's typing there was invisible
/// and the tab was discarded with it: a frame the person moved into that never reported counts
/// as holding their input.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct BrowserPageBusyRecorderTests {
    /// Stand-ins for Chromium's device interfaces (WebKit has none), defined before the recorder
    /// installs, as Chromium defines them before any script runs.
    private static let fakeDevices = """
        window.USBDevice = class { constructor() { this.opened = false; } async open() { this.opened = true; } async close() { this.opened = false; } };
        window.HIDDevice = class { constructor() { this.opened = false; } async open() { this.opened = true; } async close() { this.opened = false; } };
        window.SerialPort = class { constructor() { this.readable = null; } async open() { this.readable = {}; } async close() { this.readable = null; } };
        window.BluetoothRemoteGATTServer = class { constructor() { this.connected = false; } async connect() { this.connected = true; return this; }
          disconnect() { this.connected = false; } };
        return true;
        """

    private func report(_ view: WKWebView) async throws -> [String: Bool] {
        let json = try await view.evaluateJavaScript(BrowserPageBusy.probeScript) as? String
        let object = try JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8)) as? [String: Any] ?? [:]
        return object.compactMapValues { $0 as? Bool }
    }

    @Test(arguments: [("USBDevice", "open", "close"), ("HIDDevice", "open", "close"), ("SerialPort", "open", "close"),
                      ("BluetoothRemoteGATTServer", "connect", "disconnect")])
    func anOpenDeviceKeepsThePageUntilItCloses(_ kind: (name: String, open: String, close: String)) async throws {
        let view = WKWebView(frame: .zero)
        _ = try await view.callAsyncJavaScript(Self.fakeDevices, contentWorld: .page)
        _ = try await view.evaluateJavaScript(BrowserPageBusy.recorderScript + ";true")
        #expect(try await report(view)["device"] != true, "a page with no device counted as connected")
        _ = try await view.callAsyncJavaScript("window.held = new \(kind.name)(); await window.held.\(kind.open)(); return true;", contentWorld: .page)
        #expect(try await report(view)["device"] == true, "an open \(kind.name) did not keep the page")
        _ = try await view.callAsyncJavaScript("await window.held.\(kind.close)(); return true;", contentWorld: .page)
        #expect(try await report(view)["device"] == false, "a closed \(kind.name) still kept the page")
    }

    /// The person clicks into a child frame that has no recorder (Chromium's cross-origin frames).
    @Test func aChildFrameThePersonUsedThatCannotBeReadKeepsThePage() async throws {
        let page = try await Page(recorderInChildFrames: false)
        defer { page.close() }
        try await page.clickIntoFrame()
        #expect(try await report(page.view)["opaque"] == true, "the person's typing in an unreadable frame did not keep the page")
    }

    /// A frame the page focuses by itself (no activation) is not the person's. The page focuses it
    /// from its own load script and says so in its title, so no script call of the test (each
    /// carries a user gesture) runs before the focus.
    @Test func aChildFrameThePageFocusedItselfDoesNotKeepIt() async throws {
        let page = try await Page(recorderInChildFrames: false, focusesFrameItself: true)
        defer { page.close() }
        try await page.until("the page focused its frame") { page.view.title == "focused" }
        #expect(try await report(page.view)["opaque"] != true, "a frame the page focused itself kept the page")
    }

    /// A child frame with the recorder reports its own fields: nothing is unknown.
    @Test func aChildFrameWithTheRecorderIsReadNotGuessed() async throws {
        let page = try await Page(recorderInChildFrames: true)
        defer { page.close() }
        try await page.clickIntoFrame()
        #expect(try await report(page.view)["opaque"] != true, "a frame that reports for itself counted as unreadable")
    }

    /// A window with one page: a child frame at the top left holding an empty field.
    @MainActor final class Page {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view: WKWebView

        init(recorderInChildFrames: Bool, focusesFrameItself: Bool = false) async throws {
            _ = NSApplication.shared
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(WKUserScript(
                source: BrowserPageBusy.recorderScript, injectionTime: .atDocumentStart, forMainFrameOnly: !recorderInChildFrames))
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            view.loadHTMLString("""
                <!doctype html><body style="margin:0">
                <iframe id="child" style="position:absolute;left:0;top:0;width:300px;height:200px;border:0"
                  srcdoc="<body style='margin:0'><input id='f' style='width:300px;height:200px'></body>"
                  \(focusesFrameItself ? "onload=\"this.focus(); document.title = document.activeElement === this ? 'focused' : 'not'\"" : "")></iframe></body>
                """, baseURL: nil)
            guard !focusesFrameItself else { return }
            try await until("the child frame loads") {
                (try? await view.evaluateJavaScript("!!document.getElementById('child').contentDocument?.getElementById('f')") as? Bool) == true
            }
        }

        /// A click at the frame's middle, as the person's.
        func clickIntoFrame() async throws {
            window.makeFirstResponder(view)
            let point = view.convert(NSPoint(x: 150, y: view.isFlipped ? 100 : view.bounds.height - 100), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
            try await until("the click focused the frame") {
                (try? await view.evaluateJavaScript("document.activeElement.tagName") as? String) == "IFRAME"
            }
        }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }
}
