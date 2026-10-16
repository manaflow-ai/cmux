import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Draws an SF Symbol through the AppKit-hosted icon renderer with the tint
/// baked into the bitmap, the same path the Vault (`SessionIndex`) icons use.
///
/// SwiftUI must not own any pixel of the glyph. On Intel Macs running macOS
/// 15, SwiftUI raster images draw nothing, and a SwiftUI `.mask` over a hosted
/// AppKit view paints at first but goes blank after a while; an `NSImageView`
/// showing a pre-tinted bitmap stays visible. The shared renderer resolves the
/// dynamic tint under the view's effective appearance and retries the same
/// symbol through its fallback slot when a draw comes back blank.
struct CmuxHostedSystemSymbolImage: View {
    let systemName: String
    /// SF Symbol configuration point size.
    let pointSize: CGFloat
    /// Layout size of the configured symbol; the glyph draws 1:1 inside it.
    let imageSize: NSSize
    let weight: NSFont.Weight
    /// Dynamic AppKit color the renderer bakes into the bitmap.
    let tintColor: NSColor
    /// Size of the slot the glyph is centered in, matching the SwiftUI
    /// `Image(nsImage:)` frame this view replaces.
    let slotSize: CGFloat
    var alignment: Alignment = .center

    /// Builds the renderer request for a hosted symbol.
    static func iconRequest(
        systemName: String,
        pointSize: CGFloat,
        imageSize: NSSize,
        weight: NSFont.Weight,
        tintColor: NSColor
    ) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: nil),
            size: imageSize,
            tintColor: tintColor,
            symbolWeight: weight,
            fallbackSource: .systemSymbol(name: systemName, accessibilityDescription: nil),
            symbolPointSize: pointSize
        )
    }

    var body: some View {
        CmuxResolvedIconImage(request: Self.iconRequest(
            systemName: systemName,
            pointSize: pointSize,
            imageSize: imageSize,
            weight: weight,
            tintColor: tintColor
        ))
        .frame(width: imageSize.width, height: imageSize.height)
        .frame(width: slotSize, height: slotSize, alignment: alignment)
        .accessibilityHidden(true)
    }
}
