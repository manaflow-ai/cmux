import SwiftUI

/// The four fingerprint words, two by two.
struct WordsGrid: View {
    let words: [String]
    var size: CGFloat = 13
    @Environment(\.serverColors) private var colors

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: words.count, by: 2)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + 2, words.count), id: \.self) { index in
                        HStack(spacing: 6) {
                            Text(verbatim: "\(index + 1)").font(.system(size: size * 0.7).monospacedDigit()).foregroundStyle(colors.tertiary)
                            Text(words[index]).font(.system(size: size, weight: .medium, design: .rounded)).foregroundStyle(colors.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, size * 0.45)
                        .frame(maxWidth: .infinity)
                        .card(radius: 8)
                    }
                }
            }
        }
    }
}
