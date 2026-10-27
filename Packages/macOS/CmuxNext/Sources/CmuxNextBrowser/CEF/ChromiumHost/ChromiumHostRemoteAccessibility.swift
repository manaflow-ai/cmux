import Foundation

/// Where a hosted page's accessibility stands in its page view (host mode, task 049 of
/// plans/cmux-next/chrome-parity/p01-process.md): no element yet, tokens sent to the host, the host
/// gave none, or the remote element the page view shows as its accessibility child.
///
/// The page view asks once per page it shows: a new shown tab, window or Core Animation context
/// (``reset(browser:)``) starts over, and a refusal is kept until then, so an assistive client
/// that reads the page view's children many times a second sends at most one request per page.
/// Chromium building the page's tree (``retry()``) also starts over a refusal, and a refusal of a
/// request already in flight when the tree came.
/// A reply of an earlier page (``generation``) changes nothing, as a mojo reply to a closed
/// receiver is dropped.
struct ChromiumHostRemoteAccessibility {
    enum Phase: Equatable {
        /// No request yet for the shown page.
        case idle
        /// Tokens went to the host; its reply has not come.
        case asking
        /// The host gave no token (a fork without the call, a page that went away): no request again until a reset.
        case refused
        /// The remote element is the page view's accessibility child.
        case connected
    }

    private(set) var phase = Phase.idle
    /// The browser whose page the page view shows, nil while none.
    private(set) var browser: Int32?
    /// Bumped by every ``reset(browser:)``: tags a request so a reply for an earlier page is dropped.
    private(set) var generation: UInt64 = 0
    /// The remote element while ``Phase/connected``.
    private(set) var element: AnyObject?
    /// Chromium built the page's tree while a request was in flight: the host ran it without the
    /// tree, so a refusal of it starts over instead of standing.
    private(set) var retryDue = false

    /// Starts a request for the shown page: its generation, or nil when none is due (no shown page,
    /// one in flight, refused, or connected).
    mutating func begin() -> UInt64? {
        guard phase == .idle, browser != nil else { return nil }
        phase = .asking
        return generation
    }

    /// The host's answer to the request of `generation`: `element` made from its token, nil when it
    /// gave none. False when the answer is for an earlier page or no request waits.
    mutating func answered(_ element: AnyObject?, generation: UInt64) -> Bool {
        guard generation == self.generation, phase == .asking else { return false }
        self.element = element
        phase = element != nil ? .connected : (retryDue ? .idle : .refused)
        retryDue = false
        return true
    }

    /// Chromium built the shown page's tree: a refusal starts over (true: assistive clients must
    /// read the children again, which sends the request), and a request in flight that the host
    /// refuses starts over when the refusal comes.
    mutating func retry() -> Bool {
        switch phase {
        case .refused:
            phase = .idle
            return true
        case .asking:
            retryDue = true
            return false
        case .idle, .connected:
            return false
        }
    }

    /// The page view shows another page (`browser`), window or context: the element, a refusal
    /// and any request in flight are of the old one. True when an element was shown or a request
    /// was in flight (the read that sent it waits for a layout change), so assistive clients must
    /// read the children again.
    @discardableResult
    mutating func reset(browser: Int32?) -> Bool {
        let readAgain = element != nil || phase == .asking
        generation &+= 1
        self.browser = browser
        element = nil
        phase = .idle
        retryDue = false
        return readAgain
    }
}

/// What cmux gives the host for one page's accessibility: `cmux_shim_browser_accessibility_token`'s
/// arguments. The page view's token makes the page's root element's parent in the host, the
/// window's token its window, and `embedderPID` is the process that presents it, as Chrome's app
/// shim gives the browser process its window and view tokens (`SetRemoteAccessibilityTokens`,
/// components/remote_cocoa/common/native_widget_ns_window_host.mojom).
nonisolated struct ChromiumHostAccessibilityRequest: Equatable, Sendable {
    var browser: Int32
    var embedderPID: Int32
    var viewToken: [UInt8]
    var windowToken: [UInt8]
}

/// The host's REPLY to `cmux_shim_browser_accessibility_token`: the result (the page token's
/// length, 0 for none), then the out buffer of the capacity cmux asked for. The token is the
/// buffer's first `length` bytes when it fit; a longer one is asked for again at its length.
nonisolated struct ChromiumHostAccessibilityToken: CEFHostReplyValue, Equatable {
    /// What cmux asks the first time: a remote element's token is tens of bytes.
    static let initialCapacity: Int32 = 1_024
    /// The host's bound on any out buffer (host_dispatch.inc `kMaxOutCapacity`).
    static let maximumCapacity: Int32 = 65_536

    var length: Int32
    var buffer: [UInt8]

    init(length: Int32, buffer: [UInt8]) {
        self.length = length
        self.buffer = buffer
    }

    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        length = try fields.int32()
        buffer = try fields.bytes()
    }

    /// The page's token, nil when the host gave none or it did not fit.
    var token: [UInt8]? {
        guard length > 0, Int(length) <= buffer.count else { return nil }
        return Array(buffer.prefix(Int(length)))
    }

    /// The capacity to ask again with when the token was longer than the buffer; nil when it fit,
    /// there was none, or it is past the host's bound.
    var retryCapacity: Int32? {
        guard Int(length) > buffer.count, length <= Self.maximumCapacity else { return nil }
        return length
    }
}
