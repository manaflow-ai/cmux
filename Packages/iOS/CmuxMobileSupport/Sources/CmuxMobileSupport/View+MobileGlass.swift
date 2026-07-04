public import SwiftUI

/// Shared Liquid Glass compatibility helpers for mobile SwiftUI surfaces.
public extension View {
    /// Glass (iOS 26+) or bordered button styling for secondary sign-in actions.
    @ViewBuilder
    func mobileGlassButton() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.bordered)
            .controlSize(.large)
        #endif
    }

    /// Prominent glass (iOS 26+) or bordered-prominent primary button styling.
    @ViewBuilder
    func mobileGlassProminentButton() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        #endif
    }

    /// Liquid Glass backing for a navigation-bar title / principal item.
    ///
    /// The terminal/chat header bar is cleared (`mobileTerminalNavigationChrome`)
    /// so the pane shows through the whole header, which leaves a plain title
    /// floating over busy terminal text and hard to read. Wrap the title in the
    /// same glass button style used by neighboring toolbar controls so the
    /// system owns the control height instead of this helper guessing padding.
    /// On iOS 18 the bar keeps a translucent material background, so the title
    /// is already backed and this is a no-op.
    @ViewBuilder
    func mobileGlassNavigationTitle() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            Button {} label: {
                self
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Compact Liquid Glass backing for a navigation-bar title item.
    ///
    /// Multi-line title content can otherwise make its glass control taller
    /// than neighboring toolbar buttons. Use SwiftUI's compact control sizing
    /// so the title remains a normal toolbar control without guessing a height.
    @ViewBuilder
    func mobileGlassCompactToolbarControl() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Non-interactive compact glass title backing.
    @ViewBuilder
    func mobileGlassCompactNavigationTitle() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            Button {} label: {
                self
            }
            .mobileGlassCompactToolbarControl()
            .allowsHitTesting(false)
            .accessibilityRemoveTraits(.isButton)
        } else {
            self.mobileGlassNavigationTitle()
        }
        #else
        self
        #endif
    }

    /// Glass (iOS 26+) or thin-material capsule pill background for input fields.
    @ViewBuilder
    func mobileGlassPill() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        #endif
    }

    /// Glass (iOS 26+) or thin-material rounded-rect background for a multi-line
    /// composer field. A capsule (``mobileGlassPill()``) over-rounds once the
    /// field grows to several lines, so the composer uses a fixed corner radius.
    @ViewBuilder
    func mobileGlassField(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.thinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self
            .background(.thinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
        #endif
    }

    /// Glass (iOS 26+) or thin-material circular background for a composer icon
    /// button (send / dismiss). Pair with a fixed-size icon label.
    @ViewBuilder
    func mobileGlassCircle() -> some View {
        #if compiler(>=6.2) && os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        #endif
    }
}
