public import AppKit
public import SwiftUI

extension NSButton {
    /// Gives the button the Liquid Glass bezel (`.glass`, macOS 26 and
    /// later), or `fallback` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`).
    public func useGlassBezel(fallback: NSButton.BezelStyle = .push) {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            bezelStyle = .glass
        } else {
            bezelStyle = fallback
        }
    }
}

extension View {
    /// The Liquid Glass button style (`.glass`, macOS 26 and later), or
    /// `.bordered` where Liquid Glass is missing
    /// (`Glass.isLiquidGlassAvailable`).
    @ViewBuilder
    public func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *), Glass.isLiquidGlassAvailable {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
