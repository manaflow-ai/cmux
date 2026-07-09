import AppKit
public import CmuxFoundation
public import SwiftUI

/// Applies the toolbar-button chrome styling for the file-preview PDF top bar,
/// selected by a ``FilePreviewPDFChromeStyleVariant``.
///
/// Each variant maps to a distinct button style, control size, and capsule
/// backing (system control group, liquid glass, material capsules, bordered
/// capsule, thin outline, or plain toolbar). The liquid-glass variant uses the
/// macOS 26 `glassEffect` when available and falls back to a layered material
/// capsule otherwise.
public struct FilePreviewPDFChromeStyleModifier: ViewModifier {
    let variant: FilePreviewPDFChromeStyleVariant

    /// Creates the chrome-style modifier for the given variant.
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
