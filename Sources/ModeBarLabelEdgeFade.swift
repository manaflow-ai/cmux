import SwiftUI

/// The mask over a mode tab's label: opaque, with a short fade at the
/// trailing edge while the label is wider than its slot.
struct ModeBarLabelEdgeFade: View {
    let naturalWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fade = min(10, max(0, naturalWidth - proxy.size.width))
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: max(0, (width - fade) / width)),
                    .init(color: .black.opacity(fade > 0 ? 0 : 1), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
