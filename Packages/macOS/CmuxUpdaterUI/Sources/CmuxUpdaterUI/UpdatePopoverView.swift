public import SwiftUI
public import CmuxUpdater
import AppKit
@preconcurrency import Sparkle

/// Popover view that displays detailed update information and actions.
public struct UpdatePopoverView: View {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    private let dismiss: () -> Void

    /// Creates the popover.
    ///
    /// - Parameters:
    ///   - model: The observable update state.
    ///   - actions: The host that performs update actions the popover triggers.
    ///   - dismiss: Closes the popover.
    public init(model: UpdateStateModel, actions: any UpdateActionsHost, dismiss: @escaping () -> Void = {}) {
        self.model = model
        self.actions = actions
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.effectiveState {
            case .idle:
                if model.showsDetectedBackgroundUpdate,
                   let detectedItem = model.detectedUpdateItem {
                    DetectedBackgroundUpdateView(item: detectedItem, actions: actions, dismiss: dismiss)
                } else if let detectedVersion = model.detectedUpdateVersion,
                          model.showsDetectedBackgroundUpdate {
                    DetectedBackgroundUpdatePendingView(version: detectedVersion)
                } else {
                    EmptyView()
                }

            case .permissionRequest(let request):
                PermissionRequestView(request: request, dismiss: dismiss)

            case .checking(let checking):
                CheckingView(checking: checking, dismiss: dismiss)

            case .updateAvailable(let update):
                UpdateAvailableView(update: update, dismiss: dismiss)

            case .downloading(let download):
                DownloadingView(download: download, dismiss: dismiss)

            case .extracting(let extracting):
                ExtractingView(extracting: extracting)

            case .installing(let installing):
                InstallingView(installing: installing, dismiss: dismiss)

            case .notFound(let notFound):
                NotFoundView(notFound: notFound, dismiss: dismiss)

            case .error(let error):
                UpdateErrorView(error: error, logPath: actions.updateLogPath, dismiss: dismiss)
            }
        }
        .frame(width: 300)
    }
}

private struct UpdateMetadataView: View {
    let item: SUAppcastItem
    let labelWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "update.popover.version", defaultValue: "Version:"))
                    .foregroundColor(.secondary)
                    .frame(width: labelWidth, alignment: .trailing)
                Text(item.displayVersionString)
            }
            .font(.system(size: 11))

            if item.contentLength > 0 {
                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.size", defaultValue: "Size:"))
                        .foregroundColor(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file))
                }
                .font(.system(size: 11))
            }

            if let date = item.date {
                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.released", defaultValue: "Released:"))
                        .foregroundColor(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.system(size: 11))
            }
        }
        .textSelection(.enabled)
    }
}

private struct UpdateReleaseNotesLink: View {
    let notes: UpdateState.ReleaseNotes

    var body: some View {
        Link(destination: notes.url) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                Text(notes.label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
            }
            .foregroundColor(.primary)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DetectedBackgroundUpdateView: View {
    let item: SUAppcastItem
    let actions: any UpdateActionsHost
    let dismiss: () -> Void

    private let labelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "update.popover.updateAvailable", defaultValue: "Update Available"))
                        .font(.system(size: 13, weight: .semibold))

                    UpdateMetadataView(item: item, labelWidth: labelWidth)
                }

                HStack(spacing: 8) {
                    Button(String(localized: "common.later", defaultValue: "Later")) {
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button(String(localized: "common.installAndRelaunch", defaultValue: "Install and Relaunch")) {
                        actions.attemptUpdate()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)

            if let notes = UpdateState.ReleaseNotes(displayVersionString: item.displayVersionString) {
                Divider()
                UpdateReleaseNotesLink(notes: notes)
            }
        }
    }
}

private struct DetectedBackgroundUpdatePendingView: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.updateAvailable", defaultValue: "Update Available"))
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.version", defaultValue: "Version:"))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(version)
                }
                .font(.system(size: 11))
            }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "update.popover.checking", defaultValue: "Checking for updates…"))
                    .font(.system(size: 13))
            }
        }
        .padding(16)
    }
}

private struct PermissionRequestView: View {
    let request: UpdateState.PermissionRequest
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.enableAutoUpdates", defaultValue: "Enable automatic updates?"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "update.popover.autoUpdatesDescription", defaultValue: "cmux can automatically check for updates in the background."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(String(localized: "common.notNow", defaultValue: "Not Now")) {
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: false,
                        sendSystemProfile: false
                    ))
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "common.allow", defaultValue: "Allow")) {
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: true,
                        sendSystemProfile: false
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

private struct CheckingView: View {
    let checking: UpdateState.Checking
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "update.popover.checking", defaultValue: "Checking for updates…"))
                    .font(.system(size: 13))
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

private struct UpdateAvailableView: View {
    let update: UpdateState.UpdateAvailable
    let dismiss: () -> Void

    private let labelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "update.popover.updateAvailable", defaultValue: "Update Available"))
                        .font(.system(size: 13, weight: .semibold))

                    UpdateMetadataView(item: update.appcastItem, labelWidth: labelWidth)
                }

                HStack(spacing: 8) {
                    Button(String(localized: "common.skip", defaultValue: "Skip")) {
                        update.reply(.skip)
                        dismiss()
                    }
                    .controlSize(.small)

                    Button(String(localized: "common.later", defaultValue: "Later")) {
                        update.reply(.dismiss)
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button(String(localized: "common.installAndRelaunch", defaultValue: "Install and Relaunch")) {
                        update.reply(.install)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)

            if let notes = update.releaseNotes {
                Divider()
                UpdateReleaseNotesLink(notes: notes)
            }
        }
    }
}

private struct DownloadingView: View {
    let download: UpdateState.Downloading
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.downloadingUpdate", defaultValue: "Downloading Update"))
                    .font(.system(size: 13, weight: .semibold))

                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    download.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct ExtractingView: View {
    let extracting: UpdateState.Extracting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "update.popover.preparingUpdate", defaultValue: "Preparing Update"))
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, extracting.progress)), total: 1.0)
                Text(String(format: "%.0f%%", min(1, max(0, extracting.progress)) * 100))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }
}

private struct InstallingView: View {
    let installing: UpdateState.Installing
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.restartRequired", defaultValue: "Restart Required"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "update.popover.restartRequired.message", defaultValue: "The update is ready. Please restart the application to complete the installation."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(String(localized: "common.restartLater", defaultValue: "Restart Later")) {
                    installing.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

                Spacer()

                Button(String(localized: "common.restartNow", defaultValue: "Restart Now")) {
                    installing.retryTerminatingApplication()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct NotFoundView: View {
    let notFound: UpdateState.NotFound
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.noUpdatesFound", defaultValue: "No Updates Found"))
                    .font(.system(size: 13, weight: .semibold))

                Text(String(localized: "update.popover.noUpdatesFound.message", defaultValue: "You're already running the latest version."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(String(localized: "common.ok", defaultValue: "OK")) {
                    notFound.acknowledgement()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
