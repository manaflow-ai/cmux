import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-19: "mousedown on omnibar is kinda laggy we need to from first principles make
/// it faster". The press that focuses the omnibar shows its whole result on the next frame, as in
/// Chrome: the editing look with no fade left to run, the caret or selection, and no relayout of
/// the bar (the bookmark star stays until the user types, so the field keeps its width).
@MainActor @Suite(.serialized, .closesItsWindows)
struct OmnibarMouseDownLatencyTests {
    private func bar(star: BookmarkStarState = .off) -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/some/path?query=1"), security: .none)
        bar.setBookmarkStar(star)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// A press in the bar's text area beside the text line: the bar's own focusing path (the
    /// field's text tracking would run AppKit's modal loop, which a unit test cannot feed).
    private func press(_ bar: AddressBarView, in window: NSWindow) throws {
        let area = bar.textArea
        let point = bar.convert(NSPoint(x: area.midX, y: area.maxY - 1), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }
        bar.mouseDown(with: try event(.leftMouseDown))
    }

    private func blur(_ bar: AddressBarView, in window: NSWindow) {
        window.makeFirstResponder(nil)
        #expect(!bar.isEditing)
    }

    @Test func theFocusingPressShowsTheEditingLookAtOnce() throws {
        let (bar, window) = bar()
        defer { window.closeAfterTest() }
        try press(bar, in: window)
        #expect(bar.isEditing)
        #expect(bar.pill.state == .editing)
        let fading = bar.pill.layer?.animationKeys() ?? []
        #expect(fading.isEmpty, "the editing look is still fading in after the press: \(fading)")
        #expect(bar.debugShowsEditing)
    }

    @Test func blurShowsTheRestingLookAtOnce() throws {
        let (bar, window) = bar()
        defer { window.closeAfterTest() }
        try press(bar, in: window)
        blur(bar, in: window)
        #expect(bar.pill.state == .idle)
        let fading = bar.pill.layer?.animationKeys() ?? []
        #expect(fading.isEmpty, "the resting look is still fading in after blur: \(fading)")
    }

    @Test func theFocusingPressSelectsTheWholeAddress() throws {
        let (bar, window) = bar()
        defer { window.closeAfterTest() }
        try press(bar, in: window)
        #expect(bar.debugAllSelected)
    }

    @Test func theFocusingPressKeepsTheStarAndTheFieldWidth() throws {
        let (bar, window) = bar(star: .off)
        defer { window.closeAfterTest() }
        #expect(!bar.starButton.isHidden)
        let width = bar.field.frame.width
        try press(bar, in: window)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.isEditing)
        #expect(!bar.starButton.isHidden, "focus hid the star: the press relaid the bar")
        #expect(bar.field.frame.width == width)
    }

    @Test func typingHidesTheStarAndBlurShowsItAgain() throws {
        let (bar, window) = bar(star: .on)
        defer { window.closeAfterTest() }
        bar.debugType("swift")
        bar.layoutSubtreeIfNeeded()
        #expect(bar.starButton.isHidden)
        blur(bar, in: window)
        bar.update(url: URL(string: "https://example.org/"), security: .none)
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.starButton.isHidden)
    }

    /// Budget guard: the press's own main-thread work (focus, reducer steps, the bar's look) stays
    /// far inside one frame. Median of 25 presses from rest, so one slow host tick does not fail it.
    @Test func thePressPathStaysInsideAFrame() throws {
        let (bar, window) = bar()
        defer { window.closeAfterTest() }
        var samples: [Double] = []
        for _ in 0..<25 {
            blur(bar, in: window)
            let clock = ContinuousClock()
            let elapsed = try clock.measure { try press(bar, in: window) }
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
            #expect(bar.isEditing)
        }
        let median = samples.sorted()[samples.count / 2]
        #expect(median < 4, "median press \(median) ms: \(samples.map { ($0 * 100).rounded() / 100 })")
    }
}
