import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The browser toolbar's buttons show the arrow like the rest of the chrome, as native macOS apps
/// do (user 2026-10-30: "change all pointers back to cursor-default"): the toolbar row sets the
/// cursor on every pointer move (`ArrowCursorView`), and its rule
/// (`OmnibarPointer.cursor(atWindowPoint:in:)`) gives the arrow over every button, enabled or not,
/// and over the bookmark star. The omnibar's text area keeps the I-beam.
@Suite(.closesItsWindows)
@MainActor
struct OmnibarPointerButtonTests {
    private func row(with button: NSView) -> (window: NSWindow, row: ArrowCursorView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let row = ArrowCursorView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView?.addSubview(row)
        row.addSubview(button)
        button.frame = NSRect(x: 10, y: 5, width: 30, height: 30)
        return (window, row)
    }

    private func windowPoint(atCenterOf view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    @Test func anEnabledToolbarButtonShowsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        defer { host.window.closeAfterTest() }
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    @Test func aDisabledToolbarButtonShowsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        defer { host.window.closeAfterTest() }
        button.isEnabled = false
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    @Test func theRowBesideAButtonShowsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        defer { host.window.closeAfterTest() }
        let beside = host.row.convert(NSPoint(x: 200, y: 20), to: nil)
        #expect(OmnibarPointer.cursor(atWindowPoint: beside, in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    /// A pointer move over a button sets the arrow, the cursor the row tracks.
    @Test func aMoveOverAButtonSetsTheArrow() {
        let button = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil, toolbar: true)
        let host = row(with: button)
        defer { host.window.closeAfterTest() }
        host.row.setCursor(at: windowPoint(atCenterOf: button))
        #expect(host.row.trackedCursor == .arrow)
        withExtendedLifetime(host) {}
    }

    @Test func anExtensionButtonShowsTheArrow() {
        let button = ExtensionActionButton(actionID: "test-extension")
        let host = row(with: button)
        defer { host.window.closeAfterTest() }
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .arrow)
        button.isEnabled = false
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: button), in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    @Test func theBookmarkStarShowsTheArrow() {
        let star = BookmarkStarButton(frame: .zero)
        star.state = .off
        let host = row(with: star)
        defer { host.window.closeAfterTest() }
        #expect(OmnibarPointer.cursor(atWindowPoint: windowPoint(atCenterOf: star), in: host.row) == .arrow)
        withExtendedLifetime(host) {}
    }

    /// The star registers no cursor rect of its own, so the row's arrow shows over it.
    @Test func theStarRegistersNoCursorRect() {
        let star = BookmarkStarButton(frame: .zero)
        let host = row(with: star)
        defer { host.window.closeAfterTest() }
        star.recordedCursorRects = []
        star.resetCursorRects()
        #expect(star.recordedCursorRects?.isEmpty == true)
        withExtendedLifetime(host) {}
    }

    @Test func theChromeButtonsAreClickableButtonsAndShowTheArrow() {
        let icon: NSButton = ChromeIconButton(icon: .navPreviousMatch, label: "Back", action: nil, target: nil)
        let text: NSButton = ChromeTextButton(title: "Retry", prominent: false, action: nil, target: nil)
        #expect(icon is ClickableButton)
        #expect(text is ClickableButton)
        let extensionButton: NSButton = ExtensionActionButton(actionID: "test-extension")
        #expect(extensionButton is ClickableButton)
        #expect(OmnibarPointer.cursor(.button) == .arrow)
        #expect(OmnibarPointer.cursor(.control) == .arrow)
        #expect(OmnibarPointer.cursor(.text) == .iBeam)
    }
}
