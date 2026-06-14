import SwiftUI

struct GlobalSearchEmptyStateView: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
