import AppKit
import SwiftUI
import Testing

@testable import CmuxAppKitSupportUI

@Suite
@MainActor
struct SidebarVisualEffectBackgroundTests {
    @Test
    func nativeSidebarUsesRegularUnclippedGlassWithItsConfiguredTint() throws {
        guard #available(macOS 26.0, *) else { return }
        let tint = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.10)
        let host = NSHostingView(rootView: SidebarVisualEffectBackground(
            material: .underWindowBackground,
            blendingMode: .withinWindow,
            state: .followsWindowActiveState,
            opacity: 1,
            tintColor: tint,
            cornerRadius: 12,
            preferLiquidGlass: true
        ))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        host.layoutSubtreeIfNeeded()

        let glass = try #require(Self.descendants(of: host).compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
        #expect(glass.tintColor == tint)
        #expect(glass.cornerRadius == 12)
        #expect(glass.layer?.masksToBounds != true)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
