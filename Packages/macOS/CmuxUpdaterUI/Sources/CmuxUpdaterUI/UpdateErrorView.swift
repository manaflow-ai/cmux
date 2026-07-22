import CmuxFoundation
public import SwiftUI
public import CmuxUpdater
import AppKit

struct UpdateErrorView: View {
    let error: UpdateState.Error
    let logPath: String
    let dismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        let title = UpdateStateModel.userFacingErrorTitle(for: error.error)
        let message = UpdateStateModel.userFacingErrorMessage(for: error.error)
        let downloadURL = UpdateManualDownloadRecovery().url(
            for: error.error,
            feedURLString: error.feedURLString
        )
        let details = UpdateErrorDetailsFormatter().details(
            for: error.error,
            technicalDetails: error.technicalDetails,
            feedURLString: error.feedURLString,
            logPath: logPath
        )

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .cmuxFont(size: 13)
                    Text(title)
                        .cmuxFont(size: 13, weight: .semibold)
                }

                Text(message)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let downloadURL {
                Button {
                    openURL(downloadURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text(String(localized: "update.error.downloadLatest.button", defaultValue: "Download Latest Version"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "update.popover.details", defaultValue: "Details"))
                    .cmuxFont(size: 11, weight: .semibold)
                ScrollView(.vertical) {
                    Text(details)
                        .cmuxFont(size: 10, design: .monospaced)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
            }

            HStack(spacing: 8) {
                Button(String(localized: "common.copyDetails", defaultValue: "Copy Details")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(details, forType: .string)
                }
                .controlSize(.small)

                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    error.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

                Spacer()

                Button(String(localized: "common.retry", defaultValue: "Retry")) {
                    error.retry()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
