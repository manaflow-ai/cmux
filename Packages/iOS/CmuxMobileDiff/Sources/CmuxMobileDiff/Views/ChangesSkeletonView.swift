internal import SwiftUI

struct ChangesSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.16))
                    .frame(height: index == 0 ? 18 : 12)
                    .frame(maxWidth: index == 0 ? 190 : .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .accessibilityLabel(String(localized: "diff.loading.summary", defaultValue: "Loading changed files", bundle: .module))
    }
}
