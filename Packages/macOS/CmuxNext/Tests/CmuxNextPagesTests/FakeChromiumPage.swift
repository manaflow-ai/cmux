import AppKit
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation

/// A ``PageChromiumPage`` that records the host's calls and answers `Runtime.evaluate` of the
/// sender check with ``senderURL``.
@MainActor
final class FakeChromiumPage: PageChromiumPage {
    let contentView = NSView()
    var onEvent: ((PageChromiumEvent) -> Void)?
    var resources: (@MainActor (URL) async -> PageChromiumResponse)?
    /// Every DevTools call, in order.
    private(set) var calls: [(method: String, params: [String: any Sendable])] = []
    private(set) var loaded: [URL] = []
    private(set) var zoom: Double?
    private(set) var closed = false
    var senderURL = "cmux-page://test.plain/index.html"
    var senderIsTop = true
    /// Runs after each call (tests wait on it).
    var onCall: (() -> Void)?
    /// Runs when the host closes the page.
    var onClose: (() -> Void)?

    func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        calls.append((method, params))
        defer { onCall?() }
        if method == "Runtime.evaluate", params["expression"] as? String == "[location.href, window === window.top]" {
            return #"{"result":{"type":"object","value":["\#(senderURL)",\#(senderIsTop)]}}"#
        }
        return #"{"result":{}}"#
    }

    func load(_ url: URL) { loaded.append(url) }
    func reload() {}
    func setZoom(_ zoom: Double) { self.zoom = zoom }
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func close() {
        closed = true
        onClose?()
    }

    /// The raw binding call the page script makes for `payload`.
    static func bindingCall(_ payload: [String: Any], context: Int = 9) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let event: [String: Any] = ["method": "Runtime.bindingCalled",
                                    "params": ["name": ChromiumPageHostBridge.bindingName, "payload": text, "executionContextId": context]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }
}

/// A ``PageChromiumHosting`` that hands out ``FakeChromiumPage``s, or fails.
@MainActor
final class FakeChromiumHosting: PageChromiumHosting {
    var preference: BrowserDefaultEngine = .chromium
    var isAvailable = true
    var fails = false
    private(set) var made: [FakeChromiumPage] = []
    var onMade: ((FakeChromiumPage) -> Void)?

    struct Refused: Error {}

    func serves(_ page: PageDescriptor) -> Bool { true }

    func makePage(_ page: PageDescriptor) async throws -> any PageChromiumPage {
        if fails { throw Refused() }
        let fake = FakeChromiumPage()
        fake.senderURL = page.url().absoluteString
        made.append(fake)
        onMade?(fake)
        return fake
    }
}
