#if os(iOS)
import SwiftUI

/// Keeps live gallery refreshes anchored while observing the viewport on each supported OS.
struct SessionGalleryScrollView<Content: View>: View {
    let topTolerance: CGFloat
    let onViewportChange: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 18.0, *) {
            ScrollView(content: content)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let isAtTop = geometry.contentOffset.y
                        <= geometry.contentInsets.top + topTolerance
                    let fits = geometry.contentSize.height
                        <= geometry.containerSize.height + topTolerance
                    return isAtTop || fits
                } action: { _, isAtTopOrFits in
                    onViewportChange(isAtTopOrFits)
                }
        } else {
            GeometryReader { viewport in
                let viewportHeight = viewport.size.height
                let tolerance = topTolerance
                ScrollView {
                    content()
                        .onGeometryChange(for: Bool.self) { geometry in
                            let frame = geometry.frame(in: .scrollView)
                            return frame.minY >= -tolerance
                                || frame.height <= viewportHeight + tolerance
                        } action: { isAtTopOrFits in
                            onViewportChange(isAtTopOrFits)
                        }
                }
            }
        }
    }
}
#endif
