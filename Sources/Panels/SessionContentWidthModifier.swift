import CmuxSettings
import SwiftUI

private extension SessionContentWidthPresentation {
    var swiftUIAlignment: Alignment {
        switch alignment {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }
}

/// Applies the shared width cap and horizontal placement to session surfaces.
struct SessionContentWidthModifier: ViewModifier {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedMaximumWidth = SessionContentWidthSettings.noMaximumWidth

    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedAlignment = SessionContentAlignment.center.rawValue

    let fillsHeight: Bool

    func body(content: Content) -> some View {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: storedMaximumWidth,
            storedAlignment: storedAlignment
        )
        content
            .frame(
                maxWidth: presentation.maximumWidth ?? .infinity,
                maxHeight: fillsHeight ? .infinity : nil
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: fillsHeight ? .infinity : nil,
                alignment: presentation.swiftUIAlignment
            )
    }
}

extension View {
    /// Caps terminal and agent-session content while keeping the pane full-size.
    func sessionContentWidth(fillsHeight: Bool = true) -> some View {
        modifier(SessionContentWidthModifier(fillsHeight: fillsHeight))
    }
}
