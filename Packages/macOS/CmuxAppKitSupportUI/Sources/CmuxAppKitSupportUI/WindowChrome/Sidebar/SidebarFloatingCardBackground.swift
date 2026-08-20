public import AppKit
public import SwiftUI

/// Background for the floating workspaces card: Liquid Glass when the OS
/// provides it (NSGlassEffectView), otherwise an in-window blur, tinted
/// toward the user's terminal theme so the card reads as part of the theme
/// rather than a foreign panel.
public struct SidebarFloatingCardBackground: View {
    private let cornerRadius: CGFloat
    private let tintColor: NSColor?

    public init(cornerRadius: CGFloat, tintColor: NSColor?) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
    }

    public var body: some View {
        SidebarVisualEffectBackground(
            material: .hudWindow,
            blendingMode: .withinWindow,
            state: .active,
            opacity: 1,
            tintColor: tintColor,
            cornerRadius: cornerRadius,
            preferLiquidGlass: true
        )
        .allowsHitTesting(false)
    }
}
