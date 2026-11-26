import CMUXMobileCore
import SwiftUI

@MainActor
struct IrohConnectionCheckCard: View {
    let report: CmxIrohConnectionCheckReport?
    let snapshot: CmxIrohSettingsSnapshot
    let isRunning: Bool
    let run: () -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:connectionCheck",
                String(localized: "settings.networking.check.title", defaultValue: "Connection Check"),
                subtitle: String(
                    localized: "settings.networking.check.subtitle",
                    defaultValue: "Checks encrypted transport, relay policy, and relay reachability from this Mac."
                )
            ) {
                Button(String(localized: "settings.networking.check.run", defaultValue: "Run Check"), action: run)
                    .disabled(isRunning)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsIrohRunConnectionCheck")
            }

            if isRunning {
                SettingsCardDivider()
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }
            if let report { resultRows(report) }
            SettingsCardNote(String(
                localized: "settings.networking.check.note",
                defaultValue: """
                cmux automatically uses direct internet, LAN, or any VPN route available to macOS, then \
                falls back to an allowed relay. Every route remains end-to-end encrypted.
                """
            ))
        }
    }

    @ViewBuilder
    private func resultRows(_ report: CmxIrohConnectionCheckReport) -> some View {
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:connectionCheck:path",
            String(localized: "settings.networking.check.path", defaultValue: "Active Route")
        ) {
            Text(selectedPath(report.selectedPath))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("SettingsIrohConnectionCheckPath")
        }
        ForEach(report.stages.filter { $0.status != .notApplicable }) { stage in
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:connectionCheck:\(stage.id)",
                stageTitle(stage.kind)
            ) {
                Label(stageStatus(stage.status), systemImage: stageSymbol(stage.status))
                    .foregroundStyle(stageColor(stage.status))
            }
        }
        if report.recommendation != .none {
            SettingsCardNote(recommendation(report.recommendation))
        }
        if report.recommendation == .allowRelayTraffic, !safeRelayOrigins.isEmpty {
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:networking:connectionCheck:allowlist",
                String(
                    localized: "settings.networking.check.shareAllowlist",
                    defaultValue: "IT Relay Allowlist"
                )
            ) {
                ShareLink(item: relayAllowlistText) {
                    Label(
                        String(localized: "settings.networking.check.share", defaultValue: "Share…"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsIrohShareRelayAllowlist")
            }
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:networking:connectionCheck:shareReport",
            String(
                localized: "settings.networking.check.shareReport",
                defaultValue: "Connection Report"
            )
        ) {
            ShareLink(item: supportReportText(report)) {
                Label(
                    String(localized: "settings.networking.check.share", defaultValue: "Share…"),
                    systemImage: "square.and.arrow.up"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("SettingsIrohShareConnectionReport")
        }
    }

    private var activeRelayURLs: [String] {
        switch snapshot.preference {
        case .automatic: snapshot.managedRelays.map(\.url)
        case .managed: snapshot.managedRelays.filter(\.isSelected).map(\.url)
        case .custom: snapshot.customRelays.map(\.url)
        }
    }

    private var relayAllowlistText: String {
        let header = String(
            localized: "settings.networking.check.allowlist.header",
            defaultValue: "Allow outbound HTTPS and WebSocket access to these cmux relay origins:"
        )
        return ([header] + safeRelayOrigins.map { "- \($0)" }).joined(separator: "\n")
    }

    private var safeRelayOrigins: [String] {
        activeRelayURLs.cmxIrohCanonicalRelayOrigins()
    }

    private func supportReportText(_ report: CmxIrohConnectionCheckReport) -> String {
        var lines = [
            String(
                localized: "settings.networking.check.report.header",
                defaultValue: "cmux Connection Report"
            ),
            "\(String(localized: "settings.networking.check.path", defaultValue: "Active Route")): \(selectedPath(report.selectedPath))",
        ]
        lines.append(contentsOf: report.stages.filter { $0.status != .notApplicable }.map {
            "\(stageTitle($0.kind)): \(stageStatus($0.status))"
        })
        if report.recommendation != .none {
            lines.append(
                "\(String(localized: "settings.networking.check.report.action", defaultValue: "Suggested Action")): \(recommendation(report.recommendation))"
            )
        }
        // Relay origins stay out of this report: the diagnostics privacy copy
        // promises reports exclude relay URLs. The IT allowlist carries them.
        return lines.joined(separator: "\n")
    }

    private func selectedPath(_ path: CmxIrohSelectedTransportPath) -> String {
        switch path {
        case .unavailable:
            String(
                localized: "settings.networking.check.path.unavailable",
                defaultValue: "No Live Route"
            )
        case .direct:
            String(
                localized: "settings.networking.check.path.direct",
                defaultValue: "Direct Peer-to-Peer"
            )
        case .privateNetwork:
            String(
                localized: "settings.networking.check.path.private",
                defaultValue: "LAN or Private VPN"
            )
        case let .managedRelay(provider, region):
            String(
                format: String(
                    localized: "settings.networking.check.path.managedRelay",
                    defaultValue: "cmux Relay (%1$@, %2$@)"
                ),
                provider,
                region
            )
        case let .customRelay(displayName, _, _):
            String(
                format: String(
                    localized: "settings.networking.check.path.customRelay",
                    defaultValue: "Custom Relay (%1$@)"
                ),
                displayName
            )
        }
    }

    private func stageTitle(_ kind: CmxIrohConnectionCheckReport.StageKind) -> String {
        switch kind {
        case .encryptedTransport:
            String(
                localized: "settings.networking.check.transport",
                defaultValue: "Encrypted Transport"
            )
        case .relayPolicy: String(localized: "settings.networking.check.policy", defaultValue: "Relay Policy")
        case .relayReachability:
            String(
                localized: "settings.networking.check.relay",
                defaultValue: "Relay Reachability"
            )
        case .macDiscovery: String(localized: "settings.networking.check.mac", defaultValue: "Mac Available")
        case .secureSession: String(localized: "settings.networking.check.session", defaultValue: "Secure Session")
        }
    }

    private func stageStatus(_ status: CmxIrohConnectionCheckReport.StageStatus) -> String {
        switch status {
        case .passed: String(localized: "settings.networking.check.passed", defaultValue: "Passed")
        case .warning: String(localized: "settings.networking.check.warning", defaultValue: "Needs Attention")
        case .failed: String(localized: "settings.networking.check.failed", defaultValue: "Failed")
        case .notApplicable:
            String(
                localized: "settings.networking.check.notApplicable",
                defaultValue: "Not Needed"
            )
        }
    }

    private func stageSymbol(_ status: CmxIrohConnectionCheckReport.StageStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .notApplicable: "minus.circle"
        }
    }

    private func stageColor(_ status: CmxIrohConnectionCheckReport.StageStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .notApplicable: .secondary
        }
    }

    private func recommendation(_ value: CmxIrohConnectionCheckReport.Recommendation) -> String {
        switch value {
        case .none: ""
        case .retry:
            String(
                localized: "settings.networking.check.action.retry",
                defaultValue: "Retry. If this continues, share the safe report with cmux support."
            )
        case .checkInternet:
            String(
                localized: "settings.networking.check.action.internet",
                defaultValue: "Connect this Mac to the internet, then run the check again."
            )
        case .openMacApp:
            String(
                localized: "settings.networking.check.action.mac",
                defaultValue: "Keep cmux open and confirm both apps use the same account."
            )
        case .allowRelayTraffic:
            String(
                localized: "settings.networking.check.action.relay",
                defaultValue: """
                Your network may block relay traffic. Ask IT to allow HTTPS and WebSocket access to your \
                configured cmux relay domains, or add an approved custom relay.
                """
            )
        case .refreshAccount:
            String(
                localized: "settings.networking.check.action.account",
                defaultValue: "Confirm you are signed in, then reopen cmux and run the check again."
            )
        case .reviewRelaySettings:
            String(
                localized: "settings.networking.check.action.settings",
                defaultValue: """
                Choose Automatic relay selection, or fix the selected custom relay and its device secret.
                """
            )
        case .updateOrRepair:
            String(
                localized: "settings.networking.check.action.repair",
                defaultValue: "Update cmux on both devices. If needed, pair them again."
            )
        }
    }
}
