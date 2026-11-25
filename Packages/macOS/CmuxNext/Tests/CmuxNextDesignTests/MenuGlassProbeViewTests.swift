import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Chief 2026-11-22: make the menu glass mark hard to forget. A SwiftUI button finds the menu panel it sits on in the
/// view tree (``MenuGlassProbeView``), so no content a panel hosts has to mark itself.
@MainActor @Suite(.serialized, .closesItsWindows) struct MenuGlassProbeViewTests {
    private func window(holding view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test func aProbeOnAMenuPanelReportsItsThemeOnce() {
        let panel = Glass.makeMenuPanel(interactive: true)
        let probe = MenuGlassProbeView(frame: .zero)
        var reports: [ThemeTokens?] = []
        probe.onChange = { reports.append($0) }
        #expect(reports.isEmpty, "a probe in no view reported menu glass")
        panel.contentView.addSubview(probe)
        let window = window(holding: panel)
        defer { window.close() }
        #expect(reports.count == 1)
        #expect(reports.first.flatMap { $0 } != nil, "a probe on a menu panel found no menu glass")
        #expect(probe.menuGlassTokens != nil)
        probe.viewDidChangeEffectiveAppearance()
        #expect(reports.count == 1, "the probe reported the same theme twice")
    }

    @Test func aProbeOffAMenuPanelFindsNoMenuGlass() {
        let popover = Glass.makeSurface(.popover, content: nil, cornerRadius: 8, interactive: true)
        let inPopover = MenuGlassProbeView(frame: .zero)
        popover.contentView.addSubview(inPopover)
        let plain = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let onWindow = MenuGlassProbeView(frame: .zero)
        plain.addSubview(onWindow)
        plain.addSubview(popover)
        var reports = 0
        inPopover.onChange = { _ in reports += 1 }
        onWindow.onChange = { _ in reports += 1 }
        let window = window(holding: plain)
        defer { window.close() }
        #expect(inPopover.menuGlassTokens == nil && onWindow.menuGlassTokens == nil)
        #expect(reports == 0, "a probe off a menu panel reported menu glass")
    }

    @Test func aProbeWhoseCallbackIsSetLateStillReportsItsGround() {
        let panel = Glass.makeMenuPanel(interactive: true)
        let probe = MenuGlassProbeView(frame: .zero)
        panel.contentView.addSubview(probe)
        let window = window(holding: panel)
        defer { window.close() }
        var reports: [ThemeTokens?] = []
        probe.onChange = { reports.append($0) }
        #expect(reports.count == 1 && reports.first.flatMap { $0 } != nil, "a probe moved before its callback was set lost its ground")
    }

    @Test func aProbeMovedOffItsMenuPanelReportsNoMenuGlass() {
        let panel = Glass.makeMenuPanel(interactive: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        root.addSubview(panel)
        let probe = MenuGlassProbeView(frame: .zero)
        panel.contentView.addSubview(probe)
        var last: ThemeTokens?? = .none
        probe.onChange = { last = .some($0) }
        let window = window(holding: root)
        defer { window.close() }
        #expect(last.flatMap { $0 } != nil)
        probe.removeFromSuperview()
        root.addSubview(probe)
        #expect(last == .some(nil), "a probe moved onto the window kept the menu glass")
    }
}
