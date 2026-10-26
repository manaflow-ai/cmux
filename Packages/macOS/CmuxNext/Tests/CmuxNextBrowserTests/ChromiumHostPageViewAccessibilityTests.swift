import AppKit
@testable import CmuxNextBrowser
import Testing

/// A hosted page's accessibility in its page view (p01-process-049): the first read of the page
/// view's children sends the view's and window's tokens for the shown page, once; the host's token
/// becomes a remote element child; a reply for an earlier page, window or context changes nothing;
/// a refusal is kept until the page changes or Chromium builds its tree; the host's REPLY is read
/// as the page token's length, then the out buffer.
@MainActor
@Suite struct ChromiumHostPageViewAccessibilityTests {
    /// The remote element a fake bridge makes: the token it came from.
    final class FakeRemote {
        let token: [UInt8]
        init(token: [UInt8]) { self.token = token }
    }

    /// The page view's token requests, and how to answer each.
    final class Host {
        var requests: [ChromiumHostAccessibilityRequest] = []
        var answers: [([UInt8]?) -> Void] = []
    }

    let center = NotificationCenter()

    func makePage(host: Host) -> (ChromiumHostPageView, NSWindow) {
        _ = NSApplication.shared
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() }, pageUpdateCenter: center)
        page.accessibilityBridge = ChromiumHostAccessibilityBridge(
            localToken: { $0 is NSWindow ? Array("window".utf8) : Array("view".utf8) },
            remoteElement: { token, _ in FakeRemote(token: token) },
            hitTest: { element, _ in element })
        page.accessibilityTokenSource = { request, answered in
            host.requests.append(request)
            host.answers.append(answered)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(page)
        return (page, window)
    }

    func remote(of page: ChromiumHostPageView) -> FakeRemote? {
        page.accessibilityChildren()?.compactMap { $0 as? FakeRemote }.first
    }

    @Test func theFirstReadAsksOnceAndTheAnswerBecomesTheChild() {
        let host = Host()
        let (page, window) = makePage(host: host)
        defer { window.close() }
        page.showAccessibility(of: 7)
        #expect(remote(of: page) == nil)
        #expect(host.requests == [ChromiumHostAccessibilityRequest(browser: 7, embedderPID: getpid(),
                                                                   viewToken: Array("view".utf8),
                                                                   windowToken: Array("window".utf8))])
        _ = page.accessibilityChildren()
        _ = page.accessibilityHitTest(NSPoint(x: 10, y: 10))
        #expect(host.requests.count == 1, "reads while the request is in flight send nothing")
        #expect(page.remoteAccessibilityPhaseName == "asking")

        host.answers[0](Array("page".utf8))
        #expect(remote(of: page)?.token == Array("page".utf8))
        #expect(page.accessibilityHitTest(NSPoint(x: 10, y: 10)) is FakeRemote)
        #expect(page.remoteAccessibilityPhaseName == "connected")
        _ = page.accessibilityChildren()
        #expect(host.requests.count == 1, "a connected page asks no more")
    }

    @Test func noShownPageOrNoWindowAsksNothing() {
        let host = Host()
        let (page, window) = makePage(host: host)
        defer { window.close() }
        _ = page.accessibilityChildren()
        #expect(host.requests.isEmpty, "no shown page")
        page.removeFromSuperview()
        page.showAccessibility(of: 7)
        _ = page.accessibilityChildren()
        #expect(host.requests.isEmpty, "no window to give a token of")
    }

    @Test func anotherPageWindowOrContextDropsTheElementAndLateReplies() {
        let host = Host()
        let (page, window) = makePage(host: host)
        defer { window.close() }
        page.showAccessibility(of: 7)
        _ = page.accessibilityChildren()
        host.answers[0](Array("seven".utf8))
        #expect(remote(of: page) != nil)

        // A tab switch in the pane: the element was the old page's.
        page.showAccessibility(of: 8)
        #expect(remote(of: page) == nil)
        #expect(host.requests.last?.browser == 8)
        page.showAccessibility(of: 9)
        host.answers[1](Array("eight".utf8))
        #expect(page.remoteAccessibility.element == nil, "the reply for page 8 came after page 9 showed")
        _ = page.accessibilityChildren()
        #expect(host.requests.last?.browser == 9)
        host.answers[2](Array("nine".utf8))
        #expect(remote(of: page)?.token == Array("nine".utf8))

        // A new context (the host restarted, another page window).
        #expect(page.show(contextID: 5))
        #expect(page.remoteAccessibility.element == nil)
        #expect(page.remoteAccessibility.browser == 9, "the shown page stays")
        _ = page.accessibilityChildren()
        #expect(host.requests.count == 4)
        host.answers[3](Array("nine again".utf8))
        #expect(page.show(contextID: 5), "the same context keeps the element")
        #expect(remote(of: page)?.token == Array("nine again".utf8))

        // Another window: the host made the element for the old window's token.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless,
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.contentView?.addSubview(page)
        #expect(page.remoteAccessibility.element == nil)
    }

    @Test func aRefusalIsKeptUntilChromiumBuildsTheTree() {
        let host = Host()
        let (page, window) = makePage(host: host)
        defer { window.close() }
        page.showAccessibility(of: 7)
        _ = page.accessibilityChildren()
        host.answers[0](nil)
        #expect(page.remoteAccessibilityPhaseName == "refused")
        _ = page.accessibilityChildren()
        #expect(host.requests.count == 1, "a refused page is not asked again on every read")

        page.retryRemoteAccessibility()
        _ = page.accessibilityChildren()
        #expect(host.requests.count == 2)
        host.answers[1](Array("page".utf8))
        #expect(remote(of: page) != nil)
        page.retryRemoteAccessibility()
        #expect(remote(of: page) != nil, "a connected page keeps its element")
    }

    @Test func aClosedWindowDropsTheElement() {
        let host = Host()
        let (page, window) = makePage(host: host)
        page.showAccessibility(of: 7)
        _ = page.accessibilityChildren()
        host.answers[0](Array("page".utf8))
        #expect(remote(of: page) != nil)
        window.close()
        #expect(page.remoteAccessibility.element == nil)
    }

    @Test func anInProcessPageReportsNoRemoteAccessibility() {
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), inputTarget: .pageWindow,
                                        makeLayerHost: { _ in CALayer() }, pageUpdateCenter: center)
        #expect(page.remoteAccessibilityPhaseName == nil)
    }

    /// The host's REPLY: the token's length, then the out buffer of the capacity cmux asked for
    /// (ChromiumHost/tests/host_dispatch_test.cpp `AccessibilityToken` writes the same shape).
    @Test func theReplyIsTheLengthThenTheBuffer() throws {
        func reply(_ length: Int32, _ buffer: [UInt8]) throws -> ChromiumHostAccessibilityToken {
            var body: [UInt8] = [1, 0, 4, 0]
            body += withUnsafeBytes(of: length.littleEndian) { [UInt8]($0) }
            body += [4, 0, UInt8(buffer.count & 0xff), UInt8(buffer.count >> 8)] + buffer
            var fields = try CEFHostReplyFields(encoded: body)
            let token = try ChromiumHostAccessibilityToken(reply: &fields)
            try fields.finish()
            return token
        }
        let fits = try reply(4, Array("page".utf8) + [0, 0])
        #expect(fits.token == Array("page".utf8))
        #expect(fits.retryCapacity == nil)

        let long = try reply(300, [0, 0, 0, 0])
        #expect(long.token == nil)
        #expect(long.retryCapacity == 300)

        let none = try reply(0, [0, 0])
        #expect(none.token == nil)
        #expect(none.retryCapacity == nil)

        let pastTheBound = try reply(ChromiumHostAccessibilityToken.maximumCapacity + 1, [])
        #expect(pastTheBound.retryCapacity == nil)
    }
}
