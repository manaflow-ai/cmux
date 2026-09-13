import SwiftUI

/// Covers a newly created Cloud terminal until its first visible frame.
struct CloudTerminalStartupLoadingView: View {
    let readiness: CloudTerminalReadiness

    var body: some View {
        if readiness.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(
                    localized: "cloud.terminal.loading",
                    defaultValue: "Connecting to Cloud terminal…"
                ))
                .cmuxFont(size: 13, weight: .semibold)
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }
}
