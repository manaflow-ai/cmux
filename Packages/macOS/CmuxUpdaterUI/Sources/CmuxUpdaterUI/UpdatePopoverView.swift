import CmuxFoundation
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

            case .preparingCheck(let checking):
                PreparingUpdateCheckView(checking: checking, dismiss: dismiss)

            case .checking(let checking):
                CheckingView(checking: checking, dismiss: dismiss)

            case .updateAvailable(let update):
                UpdateAvailableView(update: update, actions: actions, dismiss: dismiss)

            case .downloading(let download):
                DownloadingView(download: download, dismiss: dismiss)

            case .startingDownload:
                StartingUpdateDownloadView()

            case .extracting(let extracting):
                ExtractingView(extracting: extracting)

            case .installing(let installing):
                if let blockers = installing.relaunchBlockers {
                    WaitingToRelaunchView(installing: installing, blockers: blockers, dismiss: dismiss)
                } else {
                    InstallingView(installing: installing, dismiss: dismiss)
                }

            case .notFound(let notFound):
                NotFoundView(notFound: notFound, dismiss: dismiss)

            case .error(let error):
                UpdateErrorView(
                    error: error,
                    logPath: actions.updateLogPath,
                    actions: actions,
                    dismiss: dismiss
                )
            }
        }
        .frame(width: popoverWidth)
    }

    /// One width owner for every state: a child frame wider than this is centered
    /// and clipped on both edges by the popover.
    private var popoverWidth: CGFloat {
        if case .installing(let installing) = model.effectiveState,
           installing.relaunchBlockers != nil {
            // Room for Wait, Update When These Finish, and Update Anyway on one row.
            return 340
        }
        return 300
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
            .cmuxFont(size: 11)

            if item.contentLength > 0 {
                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.size", defaultValue: "Size:"))
                        .foregroundColor(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file))
                }
                .cmuxFont(size: 11)
            }

            if let date = item.date {
                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.released", defaultValue: "Released:"))
                        .foregroundColor(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
                .cmuxFont(size: 11)
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
                    .cmuxFont(size: 11)
                Text(notes.label)
                    .cmuxFont(size: 11, weight: .medium)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .cmuxFont(size: 10)
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
                        .cmuxFont(size: 13, weight: .semibold)

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
                    .cmuxFont(size: 13, weight: .semibold)

                HStack(spacing: 6) {
                    Text(String(localized: "update.popover.version", defaultValue: "Version:"))
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(version)
                }
                .cmuxFont(size: 11)
            }

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "update.popover.checking", defaultValue: "Checking for updates…"))
                    .cmuxFont(size: 13)
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
                    .cmuxFont(size: 13, weight: .semibold)

                Text(String(localized: "update.popover.autoUpdatesDescription", defaultValue: "cmux can automatically check for updates in the background."))
                    .cmuxFont(size: 11)
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

private struct UpdateAvailableView: View {
    let update: UpdateState.UpdateAvailable
    let actions: any UpdateActionsHost
    let dismiss: () -> Void

    private let labelWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "update.popover.updateAvailable", defaultValue: "Update Available"))
                        .cmuxFont(size: 13, weight: .semibold)

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
                        // Re-resolve to the latest available version at install time instead of
                        // installing the version captured when this prompt was generated, so a
                        // newer release published in the meantime is installed directly (#6366).
                        actions.attemptUpdate()
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
                    .cmuxFont(size: 13, weight: .semibold)

                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text(String(format: "%.0f%%", progress * 100))
                            .cmuxFont(size: 11)
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
                .cmuxFont(size: 13, weight: .semibold)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, extracting.progress)), total: 1.0)
                Text(String(format: "%.0f%%", min(1, max(0, extracting.progress)) * 100))
                    .cmuxFont(size: 11)
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
                    .cmuxFont(size: 13, weight: .semibold)

                Text(String(localized: "update.popover.restartRequired.message", defaultValue: "The update is ready. Please restart the application to complete the installation."))
                    .cmuxFont(size: 11)
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

/// A held update relaunch: one compact list of the agent sessions it would resume, each with
/// a safety chip and what it is doing, and the choices that fit why it is held.
private struct WaitingToRelaunchView: View {
    let installing: UpdateState.Installing
    let blockers: UpdateRelaunchBlockers
    let dismiss: () -> Void

    private var isAskingUser: Bool { installing.updateWhenClear != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.readyWaiting", defaultValue: "Update Ready"))
                    .cmuxFont(size: 13, weight: .semibold)

                Text(UpdateStateModel.relaunchBlockersDescription(blockers, askingUser: isAskingUser))
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !blockers.agents.isEmpty || blockers.runningCommandCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    // Risky first: those are the ones the user is deciding about.
                    ForEach(sortedAgents) { agent in
                        AgentRow(agent: agent)
                    }
                    if blockers.runningCommandCount > 0 {
                        HStack(spacing: 6) {
                            SafetyChip(safety: .risky)
                            Text(UpdateStateModel.runningCommandsLabel(blockers.runningCommandCount))
                                .cmuxFont(size: 11)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityIdentifier("UpdateRelaunchAgentList")
            }

            HStack {
                Button(isAskingUser
                    ? String(localized: "update.wait", defaultValue: "Wait")
                    : String(localized: "common.later", defaultValue: "Later")) {
                    installing.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

                Spacer()

                if let updateWhenClear = installing.updateWhenClear {
                    Button(String(localized: "update.updateWhenFinished", defaultValue: "Update When These Finish")) {
                        updateWhenClear()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                }

                // No default-action shortcut: this stops risky agents' commands.
                Button(blockers.needsConfirmation
                    ? String(localized: "update.updateAnyway", defaultValue: "Update Anyway")
                    : String(localized: "update.installNow", defaultValue: "Install Now")) {
                    installing.retryTerminatingApplication()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
    }

    private var sortedAgents: [UpdateRelaunchAgent] {
        let order: [UpdateResumeSafety: Int] = [.risky: 0, .care: 1, .safe: 2]
        return blockers.agents.sorted { (order[$0.safety] ?? 3) < (order[$1.safety] ?? 3) }
    }
}

private struct AgentRow: View {
    let agent: UpdateRelaunchAgent

    var body: some View {
        HStack(spacing: 6) {
            SafetyChip(safety: agent.safety)
            Text(agent.name)
                .cmuxFont(size: 11, weight: .medium)
                .lineLimit(1)
            Text(agent.activity)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(agent.location.isEmpty ? agent.activity : "\(agent.location): \(agent.activity)")
        .accessibilityElement(children: .combine)
    }
}

private struct SafetyChip: View {
    let safety: UpdateResumeSafety

    var body: some View {
        Text(UpdateStateModel.safetyLabel(safety))
            .cmuxFont(size: 9, weight: .semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
            .fixedSize()
    }

    private var color: Color {
        switch safety {
        case .safe: return .green
        case .care: return .blue
        case .risky: return .orange
        }
    }
}

private struct NotFoundView: View {
    let notFound: UpdateState.NotFound
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "update.popover.noUpdatesFound", defaultValue: "No Updates Found"))
                    .cmuxFont(size: 13, weight: .semibold)

                Text(String(localized: "update.popover.noUpdatesFound.message", defaultValue: "You're already running the latest version."))
                    .cmuxFont(size: 11)
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
