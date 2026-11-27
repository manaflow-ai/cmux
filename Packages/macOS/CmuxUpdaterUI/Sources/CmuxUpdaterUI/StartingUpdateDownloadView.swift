import SwiftUI
import CmuxFoundation

/// Sparkle accepted the install reply and has not yet emitted its download callback.
struct StartingUpdateDownloadView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "update.startingDownload",
                defaultValue: "Starting Download…"
            ))
            .cmuxFont(size: 13)
        }
        .padding(16)
    }
}
