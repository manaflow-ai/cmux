import AppKit
public import CmuxFoundation
public import SwiftUI

/// Applies the circular standalone-button chrome styling for the file-preview
/// PDF page (e.g. a floating control), selected by a
/// ``FilePreviewPDFChromeStyleVariant``.
///
/// Mirrors ``FilePreviewPDFChromeStyleModifier`` but backs each button with a
/// circular shape and secondary foreground tint instead of a capsule. The
/// liquid-glass variant uses the macOS 26 `glassEffect` in a circle when
/// available and falls back to a circular material backing otherwise.
public struct FilePreviewPDFStandaloneChromeStyleModifier: ViewModifier {
    let variant: FilePreviewPDFChromeStyleVariant

    /// Creates the standalone chrome-style modifier for the given variant.
    /// - Parameter variant: The PDF chrome style to apply.
    public init(variant: FilePreviewPDFChromeStyleVariant) {
        self.variant = variant
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch variant {
        case .systemControlGroup:
            content
                .buttonStyle(.automatic)
                .controlSize(.regular)
        case .liquidGlass:
            liquidGlassChrome(content: content)
        case .materialCapsule:
            materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.5)
        case .borderedCapsule:
            materialChrome(content: content, material: .ultraThinMaterial, strokeOpacity: 0.55)
        case .thinOutline:
            materialChrome(content: content, material: .thinMaterial, strokeOpacity: 0.75)
        case .plainToolbar:
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func liquidGlassChrome(content: Content) -> some View {
        #if compiler(>=6.3)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(Color.secondary)
                .glassEffect(.regular, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 1)
        } else {
            materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.28)
        }
        #else
        materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.28)
        #endif
    }

    private func materialChrome(
        content: Content,
        material: Material,
        strokeOpacity: Double
    ) -> some View {
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .foregroundStyle(Color.secondary)
            .background {
                Circle()
                    .fill(material)
                Circle()
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: 0.5)
            }
    }
}
