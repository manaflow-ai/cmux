public import SwiftUI

/// Shared rounded glass shell for mobile composer text fields.
///
/// Terminal rendering and GUI chat each own their text model, focus binding, and
/// send behavior, but the field's shape, padding, and Liquid Glass treatment
/// should stay identical.
///
/// An optional `header` renders INSIDE the glass container, stacked above the
/// field row and sharing its leading text inset. This is the iMessage pattern:
/// staged image thumbnails sit nested at the top of the same rounded bubble that
/// holds the text (the bubble grows to wrap them, the send button stays pinned
/// bottom-trailing), instead of floating as a detached chip row with a hand-tuned
/// inset above the field. Callers that need no header use the two-closure
/// convenience initializer (`Header == EmptyView`), which lays out exactly as
/// before.
public struct MobileComposerFieldContainer<Header: View, Field: View, Trailing: View>: View {
    private let minHeight: CGFloat
    private let cornerRadius: CGFloat
    private let header: Header
    private let field: Field
    private let trailing: Trailing

    /// Creates a shared field shell with a `header` (e.g. staged attachment
    /// thumbnails) stacked above the field row, all inside the one rounded glass
    /// container. The first (unlabeled) trailing closure is the header so the
    /// call site reads top-to-bottom in visual order.
    public init(
        minHeight: CGFloat = 40,
        cornerRadius: CGFloat = 20,
        @ViewBuilder header: () -> Header,
        @ViewBuilder field: () -> Field,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.minHeight = minHeight
        self.cornerRadius = cornerRadius
        self.header = header()
        self.field = field()
        self.trailing = trailing()
    }

    /// The field row with shared padding, sizing, and glass treatment. The header
    /// (when non-empty) stacks above the field row inside the same glass shell,
    /// left-aligned to the field's leading inset; an empty header collapses to
    /// nothing so the field-only layout is unchanged.
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .bottom, spacing: 8) {
                field
                trailing
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight, alignment: .top)
        .mobileGlassField(cornerRadius: cornerRadius)
    }
}

/// Header-less conveniences for the field container, used by callers (e.g. GUI
/// chat) that render only the field and its trailing control inside the rounded
/// glass shell.
public extension MobileComposerFieldContainer where Header == EmptyView {
    /// Creates a shared field shell with no header — just the field row and its
    /// trailing control inside the rounded glass container. Layout is identical to
    /// the header-bearing initializer with an empty header.
    init(
        minHeight: CGFloat = 40,
        cornerRadius: CGFloat = 20,
        @ViewBuilder field: () -> Field,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            minHeight: minHeight,
            cornerRadius: cornerRadius,
            header: { EmptyView() },
            field: field,
            trailing: trailing
        )
    }
}
