import AppKit
@testable import CmuxNextDesign
import Testing

/// p14-energy-055b (Q5): chrome hover tracking areas hear the pointer only while cmux is the
/// active app, so a mouse move over an inactive cmux window wakes nothing. Background windows of
/// the active app still hover (`.activeInActiveApp`, not `.activeInKeyWindow`); a
/// `CMUX_NEXT_NO_ACTIVATE=1` launch, which never activates, still tracks always.
@MainActor @Suite(.serialized) struct HoverTrackingActivityTests {
    private func activity(of view: NSView) -> [NSTrackingArea.Options] {
        view.trackingAreas.map { $0.options.intersection([.activeAlways, .activeInActiveApp, .activeInKeyWindow, .activeWhenFirstResponder]) }
    }

    private func withNoActivate<T>(_ on: Bool, _ body: () -> T) -> T {
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = on
        defer { WindowPlacement.noActivate = saved }
        return body()
    }

    @Test func hoverActivityIsTheActiveAppUnlessTheLaunchNeverActivates() {
        #expect(withNoActivate(false) { NSTrackingArea.Options.activeForHover } == .activeInActiveApp)
        #expect(withNoActivate(true) { NSTrackingArea.Options.activeForHover } == .activeAlways)
    }

    @Test func chromeHoverPointerHoverAndRevealTrackOnlyInTheActiveApp() {
        withNoActivate(false) {
            let pointerView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            let pointer = PointerHover(pointerView)
            #expect(activity(of: pointerView) == [.activeInActiveApp])

            let chromeView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            let chrome = ChromeHover(chromeView)
            chrome.updateTrackingAreas()
            #expect(activity(of: chromeView) == [.activeInActiveApp])

            let sheetView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            let sheet = ChromeHover(sheetView, tracking: .activeInKeyWindow)
            sheet.updateTrackingAreas()
            #expect(activity(of: sheetView) == [.activeInKeyWindow], "an explicit key-window scope is kept")

            let region = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            let reveal = HoverReveal(region: region)
            let window = NSWindow(contentRect: region.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = region
            region.subviews.forEach { $0.updateTrackingAreas() }
            let probeActivity = region.subviews.flatMap(activity(of:))
            #expect(!probeActivity.isEmpty)
            #expect(probeActivity.allSatisfy { $0 == .activeInActiveApp })
            withExtendedLifetime((pointer, chrome, sheet, reveal, window)) {}
        }
    }

    @Test func popupRowsAndSwatchesTrackOnlyInTheActiveApp() {
        withNoActivate(false) {
            let row = PopupRowView(leading: nil, title: "Row")
            row.updateTrackingAreas()
            #expect(activity(of: row) == [.activeInActiveApp])

            let swatch = GroupCustomSwatchView(label: "Custom")
            #expect(activity(of: swatch) == [.activeInActiveApp])
        }
    }

    @Test func aNoActivateLaunchStillHovers() {
        withNoActivate(true) {
            let row = PopupRowView(leading: nil, title: "Row")
            row.updateTrackingAreas()
            #expect(activity(of: row) == [.activeAlways])
        }
    }
}
