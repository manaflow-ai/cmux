import SwiftUI

/// Stable SwiftUI root for a recycled Cloud tree hosting view.
@MainActor
struct CloudTreeHostedRootView: View {
    let content: CloudTreeHostedContent

    var body: some View {
        content.view
    }
}
