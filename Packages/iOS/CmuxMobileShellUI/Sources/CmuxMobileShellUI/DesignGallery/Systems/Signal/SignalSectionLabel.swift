#if DEBUG
import SwiftUI

/// Renders Signal's tracked, uppercase section-label type role.
struct SignalSectionLabel: View {
    let text: String
    let color: Color

    @ScaledMetric(relativeTo: .caption2) private var tracking = 0.88

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .default, weight: .semibold))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
#endif
