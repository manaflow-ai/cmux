import SwiftUI

struct SimulatorPaneLoadingView: View {
    let title: LocalizedStringResource
    let detail: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(Text(title))
            Text(title)
                .font(.headline)
            if let detail {
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
