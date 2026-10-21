public import SwiftUI

/// SwiftUI's indeterminate `ProgressView` in the theme: `StatusIndicatorView.spinner()`, the shared
/// loading glyph in the scope's loading ink, on the shared spinner clock, for the panes whose `ProgressView` drew the appearance's gray
/// whatever the room's theme. Shown while it is in the view tree; VoiceOver reads a busy indicator.
public struct ThemedSpinner: NSViewRepresentable {
    private let size: CGFloat

    /// - Parameter size: The spinner's side (`.mini` was 10 pt, `.small` 16 pt).
    public init(size: CGFloat) { self.size = size }

    public func makeNSView(context: Context) -> StatusIndicatorView {
        let view = StatusIndicatorView.spinner()
        view.spin(true)
        return view
    }

    public func updateNSView(_ view: StatusIndicatorView, context: Context) {}

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusIndicatorView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
