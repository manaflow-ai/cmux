import AppKit
import CmuxNextCompat

/// Exercises implicit owner release with Chromium's real ancestor tracker. Normal tab-close
/// automation explicitly closes the owner, so it cannot reproduce this final-release path.
/// Only the App's debug control endpoint invokes this probe.
@MainActor
public struct BrowserRetirementProbe {
    private let engine: CEFEngine

    public init(engine: CEFEngine) { self.engine = engine }

    public func run(makeOwner: @MainActor (any BrowserTab) -> (owner: AnyObject, chrome: BrowserChromeView)) async throws -> [String: Bool] {
        guard let url = URL(string: "about:blank"),
              let page = try await engine.makeTab(BrowserTabConfiguration(initialURL: url)) as? CEFTab else {
            throw BrowserTabError.unsupported("Chromium page unavailable")
        }
        defer { page.close() }
        var mounted = Optional(makeOwner(page))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        defer { window.close() }
        window.contentView = mounted?.chrome
        window.orderBack(nil)
        for await state in ObservationStream({ page.state }) {
            if state.phase == .finished || Task.isCancelled { break }
        }
        try Task.checkCancellation()
        guard page.browserID != nil else { throw BrowserTabError.closed }
        _ = try await page.evaluate("1", world: .page, gesture: .cmux)
        weak var chrome: BrowserChromeView?
        autoreleasepool {
            chrome = mounted?.chrome
            mounted?.chrome.isHidden = true
            // Leave the hidden chrome unattached, with the CEF probe still in its subtree.
            // Drain AppKit's temporary retains here so the reply observes finalization too.
            window.contentView = nil
            mounted = nil
        }
        let detached = page.contentView.superview == nil
        var closed = false
        do { _ = try await page.evaluate("1", world: .page, gesture: .cmux) }
        catch BrowserTabError.closed { closed = true }
        return ["live_before_release": true, "closed": closed, "content_detached": detached,
                "chrome_released": chrome == nil, "passed": closed && detached && chrome == nil]
    }
}
