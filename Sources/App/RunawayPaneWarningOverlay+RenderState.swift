import SwiftUI

/// Value comparison preventing unnecessary native card updates.
extension RunawayPaneWarningOverlay.Coordinator {
    struct RenderState: Equatable {
        let warning: RunawayPaneWarning
        let width: CGFloat
        let layoutDirection: LayoutDirection
        let colorScheme: ColorScheme
    }
}
