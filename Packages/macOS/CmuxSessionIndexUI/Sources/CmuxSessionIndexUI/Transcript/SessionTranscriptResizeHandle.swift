public import SwiftUI

/// The bottom-trailing grip that resizes the transcript preview popover.
///
/// Reports an absolute proposed size (anchored at the drag's start size plus its
/// translation) through `onResize`; the host clamps it via
/// ``SessionTranscriptPreviewLayout``.
struct SessionTranscriptResizeHandle: View {
    let size: CGSize
    let resizeHelp: String
    let onResize: (CGSize) -> Void
    @State private var dragStartSize: CGSize?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.secondary.opacity(isHovered ? 0.72 : 0.42))
                    .frame(width: CGFloat(6 + index * 5), height: 1)
                    .offset(x: -4, y: CGFloat(-5 - index * 4))
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let baseSize = dragStartSize ?? size
                    dragStartSize = baseSize
                    onResize(
                        CGSize(
                            width: baseSize.width + value.translation.width,
                            height: baseSize.height + value.translation.height
                        )
                    )
                }
                .onEnded { _ in
                    dragStartSize = nil
                }
        )
        .help(resizeHelp)
    }
}
