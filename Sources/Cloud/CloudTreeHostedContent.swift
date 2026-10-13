import Observation
import SwiftUI

/// Owns the changing content of an AppKit-hosted Cloud tree row.
///
/// The hosting view keeps one `CloudTreeHostedRootView` for its lifetime. AppKit
/// can ask the outline to refresh hover state from inside a layout pass, so row
/// updates must change this model instead of replacing `NSHostingView.rootView`.
@MainActor
@Observable
final class CloudTreeHostedContent {
    var view: AnyView

    init(view: AnyView = AnyView(EmptyView())) {
        self.view = view
    }
}
