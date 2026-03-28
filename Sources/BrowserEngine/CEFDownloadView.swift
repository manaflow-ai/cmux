import SwiftUI

/// Shown in place of the browser content when the CEF framework
/// needs to be downloaded for a Chromium-engine profile.
struct CEFDownloadView: View {
    @ObservedObject private var manager = CEFFrameworkManager.shared
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(String(
                localized: "cef.download.title",
                defaultValue: "Chromium Engine Required"
            ))
            .font(.headline)

            Text(String(
                localized: "cef.download.description",
                defaultValue: "This browser profile uses the Chromium engine, which needs to be downloaded (~\(CEFFrameworkManager.estimatedDownloadSizeMB) MB)."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)

            switch manager.state {
            case .notDownloaded:
                Button(String(
                    localized: "cef.download.button",
                    defaultValue: "Download Chromium Engine"
                )) {
                    manager.download { _ in }
                }
                .buttonStyle(.borderedProminent)

            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 300)
                    Text(String(
                        localized: "cef.download.progress",
                        defaultValue: "Downloading... \(Int(progress * 100))%"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Button(String(
                    localized: "cef.download.cancel",
                    defaultValue: "Cancel"
                )) {
                    manager.cancelDownload()
                    onCancel?()
                }
                .buttonStyle(.bordered)

            case .extracting:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(String(
                        localized: "cef.download.extracting",
                        defaultValue: "Extracting framework..."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            case .ready:
                Label(String(
                    localized: "cef.download.ready",
                    defaultValue: "Chromium engine ready"
                ), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            case .failed(let message):
                VStack(spacing: 8) {
                    Label(String(
                        localized: "cef.download.failed",
                        defaultValue: "Download failed"
                    ), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button(String(
                        localized: "cef.download.retry",
                        defaultValue: "Retry"
                    )) {
                        manager.download { _ in }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
