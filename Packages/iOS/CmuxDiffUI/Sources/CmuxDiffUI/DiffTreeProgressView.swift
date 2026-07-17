import SwiftUI

struct DiffTreeProgressView: View {
    let viewedCount: Int
    let fileCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(progressLabel)
                .font(.subheadline.weight(.semibold))
            ProgressView(
                value: fileCount == 0 ? 0 : Double(viewedCount),
                total: Double(max(fileCount, 1))
            )
            .tint(.green)
        }
        .padding(.vertical, 4)
    }

    private var progressLabel: String {
        DiffLocalized().format(
            "diff.summary.viewed",
            defaultValue: "%lld of %lld viewed",
            Int64(viewedCount),
            Int64(fileCount)
        )
    }
}
