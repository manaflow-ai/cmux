import SwiftUI

struct DiffLoadingView: View {
    var body: some View {
        List {
            HStack(spacing: 10) {
                ProgressView()
                Text(loadingLabel)
                    .font(.headline)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

            ForEach(0..<6, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(width: index.isMultiple(of: 2) ? 210 : 155, height: 12)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 9)
                }
                .padding(.vertical, 7)
                .redacted(reason: .placeholder)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        #if os(iOS)
        .listRowSpacing(0)
        #endif
    }

    private var loadingLabel: String {
        DiffLocalized().string("diff.state.loadingSummary", defaultValue: "Loading changed files…")
    }
}
