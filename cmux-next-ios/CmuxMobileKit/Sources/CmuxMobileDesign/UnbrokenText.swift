#if os(iOS)
import SwiftUI
import UIKit

/// Text whose words never break mid-word: when the longest word is wider
/// than the space (the largest accessibility sizes), the text shrinks until
/// it fits (down to half size) instead of hyphenating. Lines still wrap
/// between words.
public struct UnbrokenText: View {
    let text: String
    let style: UIFont.TextStyle
    let weight: Font.Weight
    let alignment: Alignment
    @State private var width: CGFloat = 0
    /// Read so a live text size change (Control Center, Settings) redraws
    /// the text at the new size: the size comes from this, never cached.
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ text: String, style: UIFont.TextStyle = .body, weight: Font.Weight = .regular, alignment: Alignment = .leading) {
        self.text = text
        self.style = style
        self.weight = weight
        self.alignment = alignment
    }

    public var body: some View {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        let measure = UIFont.systemFont(ofSize: base, weight: weight == .semibold ? .semibold : weight == .bold ? .bold : .regular)
        let longest = text.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).size(withAttributes: [.font: measure]).width }
            .max() ?? 0
        let scale = width > 0 && longest > width ? max(0.5, (width - 1) / longest) : 1
        Text(verbatim: text)
            .font(.system(size: base * scale, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
#endif
