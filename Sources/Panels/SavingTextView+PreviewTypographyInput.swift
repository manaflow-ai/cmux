import CoreGraphics

extension SavingTextView {
    /// Raw typography settings used to skip redundant normalization work.
    struct PreviewTypographyInput: Equatable {
        let fontFamily: String
        let fontSize: CGFloat
        let lineHeight: CGFloat
    }
}
