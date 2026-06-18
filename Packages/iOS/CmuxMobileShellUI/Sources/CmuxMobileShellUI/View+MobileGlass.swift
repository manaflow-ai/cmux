import SwiftUI

extension View {
    /// Glass (iOS 26+) or bordered button styling for secondary sign-in actions.
    @ViewBuilder
    func mobileGlassButton() -> some View {
        #if os(iOS)
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
        #if os(iOS)
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

    /// Glass (iOS 26+) or thin-material capsule pill background for input fields.
    @ViewBuilder
    func mobileGlassPill() -> some View {
        #if os(iOS)
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
        #if os(iOS)
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
        #if os(iOS)
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
