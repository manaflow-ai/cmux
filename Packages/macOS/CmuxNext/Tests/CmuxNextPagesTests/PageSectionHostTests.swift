import AppKit
@testable import CmuxNextPages
import CmuxNextTestSupport
import Testing

/// A sidebar section's page host says when the section shows and hides, including when the sidebar
/// hides a view around it (the right sidebar hides the section's outer host view, never this one).
@MainActor @Suite(.closesItsWindows) struct PageSectionHostTests {
    final class Log { var shown: [Bool] = [] }

    static func mounted() -> (NSWindow, outer: NSView, host: PageSectionHost, log: Log) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let host = PageSectionHost(page: nil)
        outer.addSubview(host)
        let log = Log()
        host.onShownChange = { log.shown.append($0) }
        window.contentView?.addSubview(outer)
        return (window, outer, host, log)
    }

    @Test func hidingAnAncestorHidesTheSectionAndShowingItBringsItBack() {
        let (window, outer, host, log) = Self.mounted()
        defer { window.close() }
        #expect(host.isShown)
        outer.isHidden = true
        #expect(!host.isShown, "the sidebar hid the section's outer view")
        outer.isHidden = false
        #expect(host.isShown)
        #expect(log.shown == [false, true, false, true], "the first value is the state when the callback is set, then each change")
    }

    @Test func leavingTheWindowHidesTheSection() {
        let (window, outer, host, log) = Self.mounted()
        defer { window.close() }
        outer.removeFromSuperview()
        #expect(!host.isShown)
        #expect(log.shown.last == false)
    }
}
