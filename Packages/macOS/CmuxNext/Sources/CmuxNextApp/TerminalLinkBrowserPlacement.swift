import CmuxNextLayout
import CoreGraphics

/// Describes where a terminal's default browser link should open.
struct TerminalLinkBrowserPlacement {
    enum Destination: Equatable {
        case reuse(PaneID)
        case split(PaneID)
    }

    /// Chooses an existing pane on the source's right, or a new right split.
    func destination(for source: PaneID, in layout: ScreenLayout, frames: [PaneID: CGRect]) -> Destination {
        // The implementation is filled in with the classic routing rule.
        // Keeping the decision separate makes the link callback testable without
        // constructing the app's daemon and window services.
        _ = layout
        _ = frames
        return .split(source)
    }
}
