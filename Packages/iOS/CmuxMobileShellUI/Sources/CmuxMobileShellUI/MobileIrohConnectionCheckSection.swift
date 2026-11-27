#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

@MainActor
struct MobileIrohConnectionCheckSection: View {
    let report: CmxIrohConnectionCheckReport?
    let relayURLs: [String]
    let isRunning: Bool
    let run: () -> Void

    var body: some View {
        Section {
            Button(action: run) {
                HStack {
                    Label(
                        L10n.string(
                            "mobile.iroh.check.run",
                            defaultValue: "Check Connection"
                        ),
                        systemImage: "stethoscope"
                    )
                    Spacer()
                    if isRunning { ProgressView() }
                }
            }
            .disabled(isRunning)
            .accessibilityIdentifier("MobileIrohRunConnectionCheck")

            if let report {
                LabeledContent(
                    L10n.string("mobile.iroh.check.path", defaultValue: "Active Route"),
                    value: selectedPath(report.selectedPath)
                )
                .accessibilityIdentifier("MobileIrohConnectionCheckPath")

                ForEach(report.stages) { stage in
                    LabeledContent(stageTitle(stage.kind)) {
                        // A Label as the LabeledContent value inflates the row
                        // to several hundred points on iOS 26 Forms; a plain
                        // HStack keeps the standard row height.
                        HStack(spacing: 5) {
                            Image(systemName: stageSymbol(stage.status))
                            Text(stageStatus(stage.status))
                        }
                        .foregroundStyle(stageColor(stage.status))
                    }
                }
                if report.recommendation != .none {
                    Label(recommendation(report.recommendation), systemImage: "lightbulb.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("MobileIrohConnectionCheckAction")
                }
                if report.recommendation == .allowRelayTraffic,
                   !safeRelayOrigins.isEmpty {
                    ShareLink(item: relayAllowlistText) {
                        Label(
                            L10n.string(
                                "mobile.iroh.check.shareAllowlist",
                                defaultValue: "Share IT Allowlist"
                            ),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .accessibilityIdentifier("MobileIrohShareRelayAllowlist")
                }
                ShareLink(item: supportReportText(report)) {
                    Label(
                        L10n.string(
                            "mobile.iroh.check.shareReport",
                            defaultValue: "Share Connection Report"
                        ),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .accessibilityIdentifier("MobileIrohShareConnectionReport")
            }
        } header: {
            Text(L10n.string(
                "mobile.iroh.check.title",
                defaultValue: "Connection Check"
            ))
        } footer: {
            Text(L10n.string(
                "mobile.iroh.check.footer",
                defaultValue: """
                cmux automatically uses direct internet, LAN, or any VPN route available to iOS, then \
                falls back to an allowed relay. Every route remains end-to-end encrypted.
                """
            ))
        }
    }

    private var relayAllowlistText: String {
        let header = L10n.string(
            "mobile.iroh.check.allowlist.header",
            defaultValue: "Allow outbound HTTPS and WebSocket access to these cmux relay origins:"
        )
        return ([header] + safeRelayOrigins.map { "- \($0)" }).joined(separator: "\n")
    }

    private var safeRelayOrigins: [String] {
        relayURLs.cmxIrohCanonicalRelayOrigins()
    }

    private func supportReportText(_ report: CmxIrohConnectionCheckReport) -> String {
        var lines = [
            L10n.string(
                "mobile.iroh.check.report.header",
                defaultValue: "cmux Connection Report"
            ),
            "\(L10n.string("mobile.iroh.check.path", defaultValue: "Active Route")): \(selectedPath(report.selectedPath))",
        ]
        lines.append(contentsOf: report.stages.map {
            "\(stageTitle($0.kind)): \(stageStatus($0.status))"
        })
        if report.recommendation != .none {
            lines.append(
                "\(L10n.string("mobile.iroh.check.report.action", defaultValue: "Suggested Action")): \(recommendation(report.recommendation))"
            )
        }
        // Relay origins stay out of this report: the diagnostics privacy copy
        // promises reports exclude relay URLs. Share IT Allowlist carries them.
        return lines.joined(separator: "\n")
    }

    private func selectedPath(_ path: CmxIrohSelectedTransportPath) -> String {
        switch path {
        case .unavailable:
            L10n.string("mobile.iroh.check.path.unavailable", defaultValue: "No Live Route")
        case .direct:
            L10n.string("mobile.iroh.check.path.direct", defaultValue: "Direct Peer-to-Peer")
        case .privateNetwork:
            L10n.string("mobile.iroh.check.path.private", defaultValue: "LAN or Private VPN")
        case let .managedRelay(provider, region):
            String(
                format: L10n.string(
                    "mobile.iroh.check.path.managedRelay",
                    defaultValue: "cmux Relay (%1$@, %2$@)"
                ),
                provider,
                region
            )
        case let .customRelay(displayName, _, _):
            String(
                format: L10n.string(
                    "mobile.iroh.check.path.customRelay",
                    defaultValue: "Custom Relay (%1$@)"
                ),
                displayName
            )
        }
    }

    private func stageTitle(_ kind: CmxIrohConnectionCheckReport.StageKind) -> String {
        switch kind {
        case .encryptedTransport:
            L10n.string("mobile.iroh.check.transport", defaultValue: "Encrypted Transport")
        case .relayPolicy:
            L10n.string("mobile.iroh.check.policy", defaultValue: "Relay Policy")
        case .relayReachability:
            L10n.string("mobile.iroh.check.relay", defaultValue: "Relay Reachability")
        case .macDiscovery:
            L10n.string("mobile.iroh.check.mac", defaultValue: "Mac Available")
        case .secureSession:
            L10n.string("mobile.iroh.check.session", defaultValue: "Secure Session")
        }
    }

    private func stageStatus(_ status: CmxIrohConnectionCheckReport.StageStatus) -> String {
        switch status {
        case .passed: L10n.string("mobile.iroh.check.passed", defaultValue: "Passed")
        case .warning: L10n.string("mobile.iroh.check.warning", defaultValue: "Needs Attention")
        case .failed: L10n.string("mobile.iroh.check.failed", defaultValue: "Failed")
        case .notApplicable: L10n.string("mobile.iroh.check.notApplicable", defaultValue: "Not Needed")
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
        case .none:
            ""
        case .retry:
            L10n.string(
                "mobile.iroh.check.action.retry",
                defaultValue: "Retry. If this continues, share the safe report with cmux support."
            )
        case .checkInternet:
            L10n.string(
                "mobile.iroh.check.action.internet",
                defaultValue: "Connect this iPhone to the internet, then run the check again."
            )
        case .openMacApp:
            L10n.string(
                "mobile.iroh.check.action.mac",
                defaultValue: "Open cmux on your Mac and confirm both apps use the same account."
            )
        case .allowRelayTraffic:
            L10n.string(
                "mobile.iroh.check.action.relay",
                defaultValue: """
                Your network may block relay traffic. Ask IT to allow HTTPS and WebSocket access to your \
                configured cmux relay domains, or add an approved custom relay.
                """
            )
        case .refreshAccount:
            L10n.string(
                "mobile.iroh.check.action.account",
                defaultValue: "Confirm you are signed in, then reopen cmux and run the check again."
            )
        case .reviewRelaySettings:
            L10n.string(
                "mobile.iroh.check.action.settings",
                defaultValue: """
                Choose Automatic relay selection, or fix the selected custom relay and its device secret.
                """
            )
        case .updateOrRepair:
            L10n.string(
                "mobile.iroh.check.action.repair",
                defaultValue: "Update cmux on both devices. If needed, remove and pair the Mac again."
            )
        }
    }
}
#endif
