public import SwiftUI

/// A bottom-trailing resize grip rendered as three stacked capsules that brighten
/// on hover. Dragging reports the running size to ``onResize``, computed from the
/// size captured at the start of the gesture plus the drag translation, so a single
/// continuous drag resizes relative to where it began rather than accumulating.
///
/// The localized help string is supplied by the caller (``helpText``) because
/// `String(localized:)` must be resolved against the app bundle, not this package's.
public struct SessionTranscriptResizeHandle: View {
    private let size: CGSize
    private let onResize: (CGSize) -> Void
    private let helpText: String
    @State private var dragStartSize: CGSize?
    @State private var isHovered = false

    /// Creates a resize handle.
    /// - Parameters:
    ///   - size: The current size of the resized surface; the drag baseline when a gesture begins.
    ///   - onResize: Called continuously during the drag with the new size.
    ///   - helpText: The localized tooltip shown on hover (resolved app-side).
    public init(
        size: CGSize,
        onResize: @escaping (CGSize) -> Void,
        helpText: String
    ) {
        self.size = size
        self.onResize = onResize
        self.helpText = helpText
    }

    public var body: some View {
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
        .help(helpText)
    }
}
