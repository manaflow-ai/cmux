import SwiftUI

struct CmuxTextStyleMetrics {
    let style: Font.TextStyle

    var baseSize: CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .subheadline: return 11
        case .body: return 13
        case .callout: return 12
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 9
        @unknown default: return 13
        }
    }

    var baseWeight: Font.Weight {
        switch style {
        case .headline: return .semibold
        default: return .regular
        }
    }
}
