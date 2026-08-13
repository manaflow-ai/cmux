public import SwiftUI

/// Shared compatibility helpers for mobile SwiftUI surfaces.
///
/// These helpers keep their historical names because they are used by the
/// terminal and mobile packages, but the controls intentionally use the
/// platform's quiet, opaque surfaces. A terminal or task editor is a work
/// surface, so decorative translucency should not compete with the content.
public extension View {
    /// Bordered button styling for secondary actions.
    @ViewBuilder
    func mobileGlassButton() -> some View {
        self
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .controlSize(.large)
    }

    /// Bordered-prominent primary button styling.
    @ViewBuilder
    func mobileGlassProminentButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .controlSize(.large)
    }

    /// Compatibility no-op for callers that used to wrap a navigation title in
    /// a Liquid Glass capsule. The navigation bar owns title contrast now.
    @ViewBuilder
    func mobileGlassNavigationTitle() -> some View {
        self
    }

    /// Compatibility no-op for compact toolbar controls.
    @ViewBuilder
    func mobileGlassCompactToolbarControl() -> some View {
        self
    }

    /// Compatibility no-op for non-interactive compact titles.
    @ViewBuilder
    func mobileGlassCompactNavigationTitle() -> some View {
        self
    }

    /// Quiet rounded control surface for compact input and action controls.
    ///
    /// The old name is retained for source compatibility. This is deliberately
    /// a rounded rectangle rather than a capsule, which keeps short controls
    /// from turning every toolbar into a row of pills.
    @ViewBuilder
    func mobileGlassPill() -> some View {
        #if os(iOS)
        self
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
            )
        #else
        self
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            )
        #endif
    }

    /// Quiet rounded-rect background for a multi-line composer field.
    @ViewBuilder
    func mobileGlassField(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(iOS)
        self
            .background(Color(uiColor: .secondarySystemBackground), in: shape)
            .overlay(shape.stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
        #else
        self
            .background(.quaternary, in: shape)
            .overlay(shape.stroke(.separator.opacity(0.45), lineWidth: 0.5))
        #endif
    }

    /// Quiet circular background for a composer icon button (send / dismiss).
    @ViewBuilder
    func mobileGlassCircle() -> some View {
        #if os(iOS)
        self
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            .overlay(Circle().stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
        #else
        self
            .background(.quaternary, in: Circle())
            .overlay(Circle().stroke(.separator.opacity(0.45), lineWidth: 0.5))
        #endif
    }
}
