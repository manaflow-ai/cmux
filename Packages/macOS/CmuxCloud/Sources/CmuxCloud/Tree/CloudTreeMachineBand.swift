import CmuxFoundation
import SwiftUI

/// The full-width tinted band `sections`-family machine rows sit in; a plain
/// pass-through elsewhere.
public struct CloudTreeMachineBand<Content: View>: View {
    public init(
        style: CloudTreeStyle,
        content: @escaping () -> Content
    ) {
        self.style = style
        self.content = content
    }

    public let style: CloudTreeStyle
    @ViewBuilder public var content: () -> Content
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    public var body: some View {
        if style.machineBand {
            content()
                // Inset the whole identity inside the band; this is independent
                // of the shared icon-to-label gap used within the content.
                .padding(.leading, 6)
                .padding(.vertical, GlobalFontMagnification.scaledSize(
                    style.machineBandVerticalPadding, percent: magnification
                ))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .padding(.trailing, style.rowGrid.trailingPadding - 2)
        } else {
            content()
                .padding(.trailing, style.rowGrid.trailingPadding)
        }
    }
}
