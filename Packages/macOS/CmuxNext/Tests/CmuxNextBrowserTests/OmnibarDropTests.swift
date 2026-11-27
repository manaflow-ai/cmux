import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// A drop on the omnibar (Chromium `OmniboxViewViews::PerformDrop`): the dropped URL, else the
/// dropped text with its whitespace collapsed, replaces the box's text, with `javascript:` stripped;
/// the box takes focus with all of it selected, and nothing loads until Enter.
@MainActor @Suite(.serialized, .closesItsWindows)
struct OmnibarDropTests {
    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        var state = state
        var effects: [OmnibarEffect] = []
        for input in inputs {
            let step = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver())
            state = step.state
            effects += step.effects
        }
        return (state, effects)
    }

    @Test func aDropReplacesTheTextAllSelectedAndLoadsNothing() throws {
        let page = OmnibarState(pageURL: try #require(URL(string: "https://example.com/a")))
        let (state, effects) = reduce(page, [.focusGained(.programmatic), .dropped("https://swift.org/documentation/")])
        #expect(state.phase == .editing)
        #expect(state.fieldText == "https://swift.org/documentation/")
        #expect(state.edit.selection == NSRange(location: 0, length: 32))
        #expect(state.edit.inlineCompletion.isEmpty)
        #expect(!effects.contains { if case .ended = $0 { true } else { false } }, "a drop never commits")
        #expect(effects.contains { if case .query = $0 { true } else { false } }, "suggestions follow the dropped text")
    }

    @Test(arguments: [("javascript:alert(1)", "alert(1)"),
                      ("JavaScript: javascript:void(0)", "void(0)"),
                      ("  two\n words  \t here ", "two words here")])
    func droppedTextIsCleaned(_ dropped: String, _ expected: String) {
        let (state, _) = reduce(OmnibarState(), [.focusGained(.programmatic), .dropped(dropped)])
        #expect(state.fieldText == expected)
    }

    private func restingBar() -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/a"), security: .secure)
        return (bar, window)
    }

    /// The bar at rest takes the dropped text: it focuses, shows the text, all selected.
    @Test func theBarTakesADroppedURLAndFocuses() {
        let (bar, window) = restingBar()
        defer { window.closeAfterTest() }
        #expect(bar.acceptDrop("https://swift.org/"))
        #expect(bar.isEditing)
        #expect(bar.displayedText == "https://swift.org/")
        #expect(bar.debugAllSelected)
    }

    /// Nothing the box shows (an image drag, whitespace only): the bar refuses it and stays at rest.
    @Test func theBarRefusesADropWithNothingToShow() {
        let (bar, window) = restingBar()
        defer { window.closeAfterTest() }
        #expect(!bar.acceptDrop(nil))
        #expect(!bar.isEditing)
    }
}
