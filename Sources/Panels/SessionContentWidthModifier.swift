import CmuxSettings
import SwiftUI

/// Applies the shared width cap and horizontal placement to session surfaces.
struct SessionContentWidthModifier: ViewModifier {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedMaximumWidth = SessionContentWidthSettings.noMaximumWidth

    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedAlignment = SessionContentAlignment.center.rawValue

    private let widthSettings = SessionContentWidthSettings()

    func body(content: Content) -> some View {
        content
            .frame(
                maxWidth: widthSettings.configuredMaximumWidth(from: storedMaximumWidth) ?? .infinity,
                maxHeight: .infinity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: swiftUIAlignment)
    }

    private var swiftUIAlignment: Alignment {
        switch SessionContentAlignment(rawValue: storedAlignment) ?? .center {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }
}

extension View {
    /// Caps terminal and agent-session content while keeping the pane full-size.
    func sessionContentWidth() -> some View {
        modifier(SessionContentWidthModifier())
    }
}
