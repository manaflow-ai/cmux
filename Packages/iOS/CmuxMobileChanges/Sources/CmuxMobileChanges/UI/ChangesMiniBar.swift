import SwiftUI

struct ChangesMiniBar: View {
    let additions: Int
    let deletions: Int
    let theme: ChangesTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(at: index))
                    .frame(width: 3, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private var filledCount: Int {
        min(5, additions + deletions)
    }

    private var additionCount: Int {
        let total = additions + deletions
        guard total > 0 else { return 0 }
        return min(filledCount, Int((Double(additions) / Double(total) * Double(filledCount)).rounded()))
    }

    private func color(at index: Int) -> Color {
        guard index < filledCount else { return Color.secondary.opacity(0.18) }
        return index < additionCount ? theme.addedStatus : theme.deletedStatus
    }
}
