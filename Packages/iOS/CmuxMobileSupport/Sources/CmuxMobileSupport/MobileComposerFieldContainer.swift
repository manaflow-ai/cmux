public import SwiftUI

/// Shared rounded shell for mobile composer text fields.
///
/// Terminal rendering and GUI chat each own their text model, focus binding, and
/// send behavior, but the field's shape and padding should stay identical.
public struct MobileComposerFieldContainer<Field: View, Trailing: View>: View {
    private let minHeight: CGFloat
    private let cornerRadius: CGFloat
    private let field: Field
    private let trailing: Trailing

    /// Creates a shared field shell around caller-provided text and trailing views.
    public init(
        minHeight: CGFloat = 40,
        cornerRadius: CGFloat = 20,
        @ViewBuilder field: () -> Field,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.minHeight = minHeight
        self.cornerRadius = cornerRadius
        self.field = field()
        self.trailing = trailing()
    }

    /// The field row with shared padding and sizing.
    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight, alignment: .top)
        .mobileGlassField(cornerRadius: cornerRadius)
    }
}
