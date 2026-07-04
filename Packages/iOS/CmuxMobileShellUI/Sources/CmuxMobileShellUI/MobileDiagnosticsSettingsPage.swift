#if os(iOS)
import AVFoundation
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxVoice
import Speech
import SwiftUI
import UIKit
import UserNotifications

struct MobileDiagnosticsSettingsPage: View {
    @Environment(AuthCoordinator.self) private var authCoordinator
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(ParakeetModelStore.self) private var parakeetModelStore

    let store: CMUXMobileShellStore?

    @State private var rows: [MobileDiagnosticsReportRow] = []
    @State private var isRefreshing = false
    @State private var hasLoaded = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(
                        L10n.string("mobile.diagnostics.refresh", defaultValue: "Refresh"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshing)
                .accessibilityIdentifier("MobileDiagnosticsRefresh")

                Button {
                    UIPasteboard.general.string = report().plainText
                } label: {
                    Label(
                        L10n.string("mobile.diagnostics.copyReport", defaultValue: "Copy Report"),
                        systemImage: "doc.on.doc"
                    )
                }
                .disabled(rows.isEmpty)
                .accessibilityIdentifier("MobileDiagnosticsCopyReport")
            }

            Section {
                if isRefreshing && rows.isEmpty {
                    ProgressView()
                        .accessibilityIdentifier("MobileDiagnosticsLoading")
                }

                ForEach(rows) { row in
                    MobileDiagnosticsRow(row: row)
                }
            }
        }
        .navigationTitle(L10n.string("mobile.diagnostics.title", defaultValue: "Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await refresh()
        }
        .accessibilityIdentifier("MobileDiagnosticsPage")
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        rows = []

        append(accountRow())
        append(pairedComputersRow())
        append(connectionRow())
        append(macCapabilitiesRow())
        append(await notificationsRow())
        append(microphonePermissionRow())
        append(speechPermissionRow())
        append(await voiceModelRow())

        isRefreshing = false
    }

    private func append(_ row: MobileDiagnosticsReportRow) {
        rows.append(row)
    }

    private func accountRow() -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.account", defaultValue: "Account")
        guard let email = trimmed(authCoordinator.currentUser?.primaryEmail) else {
            return row(id: "Account", label: label, value: L10n.string("mobile.settings.notSignedIn", defaultValue: "Not signed in"), status: .fail)
        }

        let teamName = authCoordinator.resolvedTeamID.flatMap { teamID in
            authCoordinator.availableTeams.first(where: { $0.id == teamID })?.displayName
        }
        let value: String
        if let teamName = trimmed(teamName) {
            value = String(
                format: L10n.string("mobile.diagnostics.accountSignedInTeamFormat", defaultValue: "%@ · %@"),
                email,
                teamName
            )
        } else {
            value = email
        }
        return row(id: "Account", label: label, value: value, status: .pass)
    }

    private func pairedComputersRow() -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.pairedComputers", defaultValue: "Paired Computers")
        let pairedMacs = store?.pairedMacs ?? []
        let activeName = trimmed(pairedMacs.first(where: \.isActive)?.resolvedName)
            ?? trimmed(store?.connectedHostName)
            ?? L10n.string("mobile.diagnostics.none", defaultValue: "None")
        let value = String(
            format: L10n.string("mobile.diagnostics.pairedComputersFormat", defaultValue: "Count: %lld · Active: %@"),
            Int64(pairedMacs.count),
            activeName
        )
        return row(id: "PairedComputers", label: label, value: value, status: pairedMacs.isEmpty ? .fail : .pass)
    }

    private func connectionRow() -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.connection", defaultValue: "Connection")
        guard let store else {
            return row(id: "Connection", label: label, value: connectionStateValue(.disconnected), status: .fail)
        }

        if store.connectionState == .connected {
            let route = store.activeRoute.map(routeDescription)
                ?? L10n.string("mobile.diagnostics.routeUnknown", defaultValue: "Route unknown")
            let value = String(
                format: L10n.string("mobile.diagnostics.connectionConnectedFormat", defaultValue: "%@ · %@"),
                connectionStateValue(.connected),
                route
            )
            return row(id: "Connection", label: label, value: value, status: .pass)
        }

        if store.isMacSwitchInFlight || store.isReconnectingStoredMac {
            return row(id: "Connection", label: label, value: L10n.string("mobile.diagnostics.connecting", defaultValue: "Connecting"), status: .info)
        }

        return row(id: "Connection", label: label, value: connectionStateValue(.disconnected), status: .fail)
    }

    private func macCapabilitiesRow() -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.macCapabilities", defaultValue: "Mac Capabilities")
        guard let store, store.connectionState == .connected else {
            return row(
                id: "MacCapabilities",
                label: label,
                value: L10n.string("mobile.diagnostics.notConnected", defaultValue: "Not connected"),
                status: .info
            )
        }

        let value = store.supportsVoiceMode
            ? L10n.string("mobile.diagnostics.voiceModeSupportedYes", defaultValue: "Voice Mode supported: Yes")
            : L10n.string("mobile.diagnostics.voiceModeSupportedNo", defaultValue: "Voice Mode supported: No (update your Mac's cmux)")
        return row(id: "MacCapabilities", label: label, value: value, status: store.supportsVoiceMode ? .pass : .fail)
    }

    private func notificationsRow() async -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.notifications", defaultValue: "Notifications")
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let permission = notificationStatusValue(settings.authorizationStatus)
        let enabled = pushCoordinator.isEnabled
            ? L10n.string("mobile.diagnostics.enabled", defaultValue: "Enabled")
            : L10n.string("mobile.diagnostics.disabled", defaultValue: "Disabled")
        let value = String(
            format: L10n.string("mobile.diagnostics.notificationsFormat", defaultValue: "Push: %@ · iOS: %@"),
            enabled,
            permission.value
        )
        let status: MobileDiagnosticsReportRow.Status = pushCoordinator.isEnabled ? permission.status : .info
        return row(id: "Notifications", label: label, value: value, status: status)
    }

    private func microphonePermissionRow() -> MobileDiagnosticsReportRow {
        let permission = microphonePermissionValue()
        return row(
            id: "Microphone",
            label: L10n.string("mobile.diagnostics.microphone", defaultValue: "Microphone"),
            value: permission.value,
            status: permission.status
        )
    }

    private func speechPermissionRow() -> MobileDiagnosticsReportRow {
        let permission = speechPermissionValue()
        return row(
            id: "Speech",
            label: L10n.string("mobile.diagnostics.speechRecognition", defaultValue: "Speech Recognition"),
            value: permission.value,
            status: permission.status
        )
    }

    private func voiceModelRow() async -> MobileDiagnosticsReportRow {
        let label = L10n.string("mobile.diagnostics.voiceModel", defaultValue: "Voice Model")
        guard parakeetModelStore.isInstalled else {
            return row(
                id: "VoiceModel",
                label: label,
                value: L10n.string("mobile.diagnostics.parakeetNotInstalled", defaultValue: "Parakeet v3: Not installed"),
                status: .info
            )
        }

        let size = await directorySizeString(at: parakeetModelStore.modelDirectory)
            ?? L10n.string("mobile.diagnostics.sizeUnknown", defaultValue: "Size unknown")
        let value = String(
            format: L10n.string("mobile.diagnostics.parakeetInstalledFormat", defaultValue: "Parakeet v3: Installed · %@"),
            size
        )
        return row(id: "VoiceModel", label: label, value: value, status: .pass)
    }

    private func report() -> MobileDiagnosticsReport {
        let version = AppVersionInfo.current()
        let snapshot = MobileDiagnosticsReportSnapshot(
            title: L10n.string("mobile.diagnostics.reportTitle", defaultValue: "cmux Diagnostics"),
            appVersionLabel: L10n.string("mobile.diagnostics.appVersion", defaultValue: "App Version"),
            appVersion: version.marketingVersion,
            buildStampLabel: L10n.string("mobile.diagnostics.buildStamp", defaultValue: "Build Stamp"),
            buildStamp: buildStamp(version),
            rows: rows
        )
        return MobileDiagnosticsReportBuilder().build(from: snapshot)
    }

    private func buildStamp(_ version: AppVersionInfo) -> String {
        let parts = [version.buildNumber, version.devTag, version.gitSHA].compactMap(trimmed)
        if parts.isEmpty {
            return L10n.string("mobile.diagnostics.unknown", defaultValue: "Unknown")
        }
        return parts.joined(separator: " · ")
    }

    private func connectionStateValue(_ state: MobileConnectionState) -> String {
        switch state {
        case .connected:
            return L10n.string("mobile.diagnostics.connected", defaultValue: "Connected")
        case .disconnected:
            return L10n.string("mobile.diagnostics.disconnected", defaultValue: "Disconnected")
        }
    }

    private func routeDescription(_ route: CmxAttachRoute) -> String {
        switch route.endpoint {
        case let .hostPort(host, port):
            return "\(route.kind.rawValue) · \(host):\(port)"
        case let .peer(id, _, directAddrs, relayURL):
            let routeTarget = relayURL ?? directAddrs.first ?? id
            return "\(route.kind.rawValue) · \(routeTarget)"
        case let .url(url):
            return "\(route.kind.rawValue) · \(url)"
        }
    }

    private func notificationStatusValue(_ status: UNAuthorizationStatus) -> PermissionDisplay {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionAuthorized", defaultValue: "Authorized"), status: .pass)
        case .denied:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionDenied", defaultValue: "Denied"), status: .fail)
        case .notDetermined:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionNotDetermined", defaultValue: "Not Determined"), status: .info)
        @unknown default:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionUnknown", defaultValue: "Unknown"), status: .info)
        }
    }

    private func microphonePermissionValue() -> PermissionDisplay {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionGranted", defaultValue: "Granted"), status: .pass)
            case .denied:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionDenied", defaultValue: "Denied"), status: .fail)
            case .undetermined:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionNotDetermined", defaultValue: "Not Determined"), status: .info)
            @unknown default:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionUnknown", defaultValue: "Unknown"), status: .info)
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionGranted", defaultValue: "Granted"), status: .pass)
            case .denied:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionDenied", defaultValue: "Denied"), status: .fail)
            case .undetermined:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionNotDetermined", defaultValue: "Not Determined"), status: .info)
            @unknown default:
                return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionUnknown", defaultValue: "Unknown"), status: .info)
            }
        }
    }

    private func speechPermissionValue() -> PermissionDisplay {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionAuthorized", defaultValue: "Authorized"), status: .pass)
        case .denied, .restricted:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionDenied", defaultValue: "Denied"), status: .fail)
        case .notDetermined:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionNotDetermined", defaultValue: "Not Determined"), status: .info)
        @unknown default:
            return PermissionDisplay(value: L10n.string("mobile.diagnostics.permissionUnknown", defaultValue: "Unknown"), status: .info)
        }
    }

    private func directorySizeString(at url: URL) async -> String? {
        let byteCount = await Task.detached(priority: .utility) {
            directorySizeBytes(at: url)
        }.value
        guard byteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func row(
        id: String,
        label: String,
        value: String,
        status: MobileDiagnosticsReportRow.Status
    ) -> MobileDiagnosticsReportRow {
        MobileDiagnosticsReportRow(id: id, label: label, value: value, status: status)
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PermissionDisplay {
    let value: String
    let status: MobileDiagnosticsReportRow.Status
}

private struct MobileDiagnosticsRow: View {
    let row: MobileDiagnosticsReportRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: row.status.systemImage)
                .foregroundStyle(row.status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                Text(row.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("MobileDiagnostics\(row.id)")
    }
}

private extension MobileDiagnosticsReportRow.Status {
    var systemImage: String {
        switch self {
        case .pass:
            return "checkmark.circle.fill"
        case .fail:
            return "xmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pass:
            return .green
        case .fail:
            return .red
        case .info:
            return .secondary
        }
    }
}

private func directorySizeBytes(at url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: []
    ) else {
        return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true else {
            continue
        }
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    return total
}
#endif
