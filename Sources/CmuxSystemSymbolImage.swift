import AppKit
import SwiftUI

/// SwiftUI symbol view backed by a materialized AppKit bitmap.
struct CmuxSystemSymbolImage: View {
    let systemName: String
    let pointSize: CGFloat
    let weight: Font.Weight?
    let alignment: Alignment

    init(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) {
        self.systemName = systemName
        self.pointSize = pointSize
        self.weight = weight
        self.alignment = alignment
    }

    var body: some View {
        if let image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: pointSize,
            weight: weight
        ) {
            Image(nsImage: image)
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: pointSize, height: pointSize, alignment: alignment)
        } else {
            CmuxResolvedIconImage(request: CmuxResolvedIconRequest(
                sources: [
                    .systemSymbol(name: systemName, accessibilityDescription: nil),
                    .systemSymbol(name: "circle.fill", accessibilityDescription: nil),
                ],
                size: NSSize(width: pointSize, height: pointSize),
                tintColor: .secondaryLabelColor,
                symbolWeight: RenderableSystemSymbol.nsFontWeightForView(weight)
            ))
            .frame(width: pointSize, height: pointSize, alignment: alignment)
        }
    }
}

private extension RenderableSystemSymbol {
    static func nsFontWeightForView(_ weight: Font.Weight?) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
