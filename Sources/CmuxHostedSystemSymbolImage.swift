import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Draws an SF Symbol through the AppKit-hosted icon renderer while keeping
/// SwiftUI foreground-style tinting.
///
/// SwiftUI raster images (`Image(nsImage:)`, `Image(decorative:)`,
/// `AsyncImage`) draw nothing on Intel Macs running macOS 15, while AppKit
/// image views hosted in SwiftUI draw normally. Masking a `.foreground`
/// filled rectangle with the hosted symbol keeps every caller's
/// `.foregroundStyle` / `.foregroundColor` semantics and the exact glyph
/// geometry of `NSImage.SymbolConfiguration(pointSize:weight:)`.
struct CmuxHostedSystemSymbolImage: View {
    let systemName: String
    /// SF Symbol configuration point size.
    let pointSize: CGFloat
    /// Layout size of the configured symbol; the glyph draws 1:1 inside it.
    let imageSize: NSSize
    let weight: NSFont.Weight
    /// Size of the slot the glyph is centered in, matching the SwiftUI
    /// `Image(nsImage:)` frame this view replaces.
    let slotSize: CGFloat
    var alignment: Alignment = .center

    /// Builds the renderer request for a hosted symbol.
    static func iconRequest(
        systemName: String,
        pointSize: CGFloat,
        imageSize: NSSize,
        weight: NSFont.Weight
    ) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: nil),
            size: imageSize,
            symbolWeight: weight,
            symbolPointSize: pointSize
        )
    }

    var body: some View {
        Rectangle()
            .fill(.foreground)
            .frame(width: imageSize.width, height: imageSize.height)
            .mask(
                CmuxResolvedIconImage(request: Self.iconRequest(
                    systemName: systemName,
                    pointSize: pointSize,
                    imageSize: imageSize,
                    weight: weight
                ))
                .frame(width: imageSize.width, height: imageSize.height)
            )
            .frame(width: slotSize, height: slotSize, alignment: alignment)
            .accessibilityHidden(true)
    }
}
