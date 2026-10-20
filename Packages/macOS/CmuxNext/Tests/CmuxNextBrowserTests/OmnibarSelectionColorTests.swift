import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Foundation
import Testing

/// The omnibar's text selection is the theme's neutral gray (`OmnibarStyle.selection`),
/// never the system blue (follow-up to the macOS 15 omnibar highlight report,
/// 2026-10-20). The os-smoke Tart VMs (macOS 15.7.7 and 26.6.2) showed the field
/// editor holding the system blue after a click on the omnibar: AppKit sets the
/// field editor up again when the click starts editing (`setUpFieldEditorAttributes`),
/// which resets what `becomeFirstResponder` had set.
@MainActor @Suite(.serialized)
struct OmnibarSelectionColorTests {
    private func bar() -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/some/path?query=1"), security: .none)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    /// The bar's own focusing press (the field's AppKit tracking needs a modal loop).
    private func press(_ bar: AddressBarView, in window: NSWindow) throws {
        let area = bar.textArea
        let point = bar.convert(NSPoint(x: area.midX, y: area.maxY - 1), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        bar.mouseDown(with: down)
    }

    private func rgba(_ color: NSColor?, in view: NSView) -> [Double]? {
        var resolved: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color?.usingColorSpace(.sRGB) }
        guard let resolved else { return nil }
        let components: [CGFloat] = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
        return components.map { (Double($0) * 1000).rounded() / 1000 }
    }

    private func selection(_ editor: NSTextView, in bar: AddressBarView) -> [Double]? {
        rgba(editor.selectedTextAttributes[.backgroundColor] as? NSColor, in: bar)
    }

    private func gray(_ bar: AddressBarView) -> [Double]? {
        rgba(bar.performWithTheme { OmnibarStyle.selection }, in: bar)
    }

    @Test func theFocusingPressSelectsInGray() throws {
        let (bar, window) = bar()
        try press(bar, in: window)
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        #expect(selection(editor, in: bar) == gray(bar))
        #expect(selection(editor, in: bar) != rgba(.selectedTextBackgroundColor, in: bar))
    }

    /// NSTextField's own mouse-down sets the field editor up again before it
    /// tracks the click; the gray must survive it.
    @Test func theGraySurvivesAppKitsFieldEditorSetUp() throws {
        let (bar, window) = bar()
        try press(bar, in: window)
        let editor = try #require(bar.field.currentEditor() as? NSTextView)
        _ = bar.field.cell?.setUpFieldEditorAttributes(editor)
        #expect(selection(editor, in: bar) == gray(bar))
    }
}
