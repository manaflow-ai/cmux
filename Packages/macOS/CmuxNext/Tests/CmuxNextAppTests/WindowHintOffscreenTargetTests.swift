import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// Click by Hint with a control outside the content view (cx-a64bb: the staged update card in
/// the sidebar). Its frame clipped to the content is a null rect, whose infinite origin trapped
/// the dedupe key; the hint walk now leaves the control out and labels the rest.
@MainActor
@Suite(.closesItsWindows)
struct WindowHintOffscreenTargetTests {
    @Test func aControlOutsideTheContentIsLeftOutWithoutCrashing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let inside = NSButton(title: "Inside", target: nil, action: nil)
        inside.frame = NSRect(x: 20, y: 20, width: 80, height: 24)
        let outside = NSButton(title: "Outside", target: nil, action: nil)
        outside.frame = NSRect(x: 2000, y: 2000, width: 80, height: 24)
        content.addSubview(inside)
        content.addSubview(outside)

        let found = WindowHintTargets.collect(in: content)
        #expect(found.targets.map(\.title) == ["Inside"])
    }
}
