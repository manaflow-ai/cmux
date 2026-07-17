import SwiftUI
import CmuxUpdater
import CmuxFoundation

/// The replacement check is waiting for Sparkle's previous session to finish.
struct PreparingUpdateCheckView: View {
    let checking: UpdateState.Checking
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(
                    localized: "update.preparingCheck",
                    defaultValue: "Preparing Update Check…"
                ))
                .cmuxFont(size: 13)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    checking.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

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
