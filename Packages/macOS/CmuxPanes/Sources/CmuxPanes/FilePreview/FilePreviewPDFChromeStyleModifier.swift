public import SwiftUI

/// Applies the capsule-shaped chrome background/border for a given
/// `FilePreviewPDFChromeStyleVariant` to a row of PDF preview controls.
public struct FilePreviewPDFChromeStyleModifier: ViewModifier {
    let variant: FilePreviewPDFChromeStyleVariant

    /// Creates the modifier for `variant`.
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
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
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
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 1)
        } else {
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                    Capsule()
                        .fill(Color.white.opacity(0.04))
                }
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.85)
                }
        }
        #else
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                Capsule()
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.85)
            }
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
            .background(material, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: 0.5)
            }
    }
}
