import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PairingView: View {
    @Binding var pairingCode: String
    let pairingChecklist: MobilePairingChecklist
    let connectionError: String?
    let connectionErrorGuidance: String?
    let versionWarning: String?
    let connectPairingCode: () async -> Void
    let acceptVersionWarning: () async -> Void
    let connectManualHost: (String, String, Int) async -> Void
    let cancelPairing: () -> Void
    let cancel: () -> Void

    @State private var isShowingScanner = false
    @State private var deviceName = UITestConfig.addDeviceName
        ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac")
    @State private var host = UITestConfig.addDeviceHost ?? ""
    @State private var port = UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)"
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor
    @State private var validationError: String?
    @State private var isPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: AddDeviceField?

    var body: some View {
        NavigationStack {
            Form {
                // Warn before the user burns a pair attempt: without an active
                // tailnet, the Mac's QR/tailnet route is normally unreachable.
                if tailscaleStatusMonitor?.status == .inactiveOrNotInstalled {
                    Section {
                        TailscaleInactiveCallout(context: .pairing)
                    }
                }

                Section {
                    TextField(
                        L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac"),
                        text: $deviceName
                    )
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.text)
                    .accessibilityIdentifier("MobileAddDeviceNameField")

                    TextField(
                        L10n.string("mobile.addDevice.hostPlaceholder", defaultValue: "your-mac.tailnet.ts.net"),
                        text: $host
                    )
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.url)
                    .accessibilityIdentifier("MobileAddDeviceHostField")

                    TextField(
                        L10n.string("mobile.addDevice.portPlaceholder", defaultValue: "58465"),
                        text: $port
                    )
                    .focused($focusedField, equals: .port)
                    .submitLabel(.done)
                    .addDeviceInputBehavior(.number)
                    .accessibilityIdentifier("MobileAddDevicePortField")
                } header: {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
                } footer: {
                    Text(L10n.string("mobile.addDevice.help", defaultValue: "Enter a Tailscale, LAN, or local host and port. QR/link pairing from that computer is still the safest setup path."))
                }
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    if UITestConfig.mockDataEnabled {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.string("mobile.addDevice.formAccessibilityLabel", defaultValue: "Add Computer form"))
                            .accessibilityIdentifier("MobileAddDeviceForm")
                    }
                    #endif
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: authManager.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark")
                            .font(.title3)
                            .foregroundStyle(authManager.isAuthenticated ? .green : .orange)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("mobile.addDevice.accountTitle", defaultValue: "This device"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(signedInAccountText)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobileAddDeviceSignedInAccount")

                            Text(L10n.string("mobile.addDevice.accountHelp", defaultValue: "Manual pairing uses this account. If it does not match the Mac, scan a QR/link from the Mac."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }

                Section {
                    ForEach(displayedPairingChecklist.steps) { check in
                        pairingCheckRow(check)
                    }
                } header: {
                    Text(L10n.string("mobile.pairing.checks.title", defaultValue: "Pairing checks"))
                } footer: {
                    Text(L10n.string("mobile.pairing.checks.help", defaultValue: "Each step updates independently so you can see whether the connection, account, or trust check needs attention."))
                }

                if let genericPairingError {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(genericPairingError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("MobilePairingError")
                            if let genericPairingGuidance {
                                Text(genericPairingGuidance)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("MobilePairingErrorGuidance")
                            }
                        }
                    }
                }

                #if os(iOS)
                Section {
                    Button {
                        isShowingScanner = true
                    } label: {
                        Label(L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code"), systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("MobileScanQRCodeButton")
                }
                #endif

                if let manualRouteWarningText {
                    Section {
                        Label {
                            Text(manualRouteWarningText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("MobileManualRouteWarning")
                    }
                }

                if let versionWarning {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label {
                                Text(L10n.string("mobile.pairing.versionWarningTitle", defaultValue: "Compatibility mismatch"))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.headline)
                            .foregroundStyle(.orange)

                            Text(versionWarning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("MobilePairingVersionWarning")

                            Button(role: .destructive) {
                                startPairingTask {
                                    await acceptVersionWarning()
                                }
                            } label: {
                                Text(L10n.string("mobile.pairing.versionWarningContinue", defaultValue: "Continue anyway"))
                            }
                            .disabled(isPairing)
                            .accessibilityIdentifier("MobilePairingVersionWarningContinueButton")
                        }
                    }
                }

            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button {
                    pair()
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Text(L10n.string("mobile.addDevice.pair", defaultValue: "Pair"))
                            .mobileButtonLoading(isPairing, tint: .white)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("MobilePairButton")
                .padding(.horizontal)
                .padding(.bottom, 8)
                .padding(.top, 24)
                .background {
                    PlatformPalette.systemBackground
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    cancelButton
                }
                #else
                ToolbarItem {
                    cancelButton
                }
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingScanner) {
            MobilePairingScannerSheet { scannedCode in
                pairingCode = scannedCode
                isShowingScanner = false
                startPairingTask {
                    await connectPairingCode()
                }
            }
        }
        .onAppear {
            analytics.capture("ios_pairing_screen_viewed", ["entry": .string("post_sign_in")])
        }
        #endif
    }

    private var cancelButton: some View {
        Button {
            pairingTask?.cancel()
            pairingTaskID = nil
            pairingTask = nil
            isPairing = false
            cancelPairing()
            cancel()
        } label: {
            Text(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
        }
    }

    private var displayedPairingChecklist: MobilePairingChecklist {
        if let validationError {
            return MobilePairingChecklist.idle.applyingFailure(.network, message: validationError)
        }
        if !isPairing, pairingChecklist == .idle {
            return .idle
        }
        return pairingChecklist
    }

    private var genericPairingError: String? {
        guard !displayedPairingChecklist.hasFailure else { return nil }
        let trimmed = connectionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var genericPairingGuidance: String? {
        let trimmed = connectionErrorGuidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private func pairingCheckRow(_ check: MobilePairingStepSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            pairingCheckIcon(check.status)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pairingCheckTitle(for: check.step))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(pairingCheckStatusText(for: check.status))
                        .font(.caption)
                        .foregroundStyle(pairingCheckStatusColor(check.status))
                }

                if check.status == .failed {
                    if let message = check.message, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("MobilePairingError")
                    }
                    if let guidance = check.guidance, !guidance.isEmpty {
                        Text(guidance)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("MobilePairingErrorGuidance")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobilePairingCheck-\(check.step.rawValue)")
    }

    @ViewBuilder
    private func pairingCheckIcon(_ status: MobilePairingStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func pairingCheckTitle(for step: MobilePairingStep) -> String {
        switch step {
        case .network:
            return L10n.string("mobile.pairing.check.network", defaultValue: "Network")
        case .authentication:
            return L10n.string("mobile.pairing.check.authentication", defaultValue: "Authentication")
        case .trust:
            return L10n.string("mobile.pairing.check.trust", defaultValue: "Trust")
        }
    }

    private func pairingCheckStatusText(for status: MobilePairingStepStatus) -> String {
        switch status {
        case .pending:
            return L10n.string("mobile.pairing.check.status.pending", defaultValue: "Waiting")
        case .inProgress:
            return L10n.string("mobile.pairing.check.status.inProgress", defaultValue: "Checking")
        case .succeeded:
            return L10n.string("mobile.pairing.check.status.succeeded", defaultValue: "Verified")
        case .failed:
            return L10n.string("mobile.pairing.check.status.failed", defaultValue: "Needs attention")
        }
    }

    private func pairingCheckStatusColor(_ status: MobilePairingStepStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .inProgress:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    private var manualRouteWarningText: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              !CmxPairingURLScheme.hasPairingScheme(trimmedHost),
              MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning(trimmedHost) else {
            return nil
        }
        return L10n.string(
            "mobile.addDevice.manualRouteWarning",
            defaultValue: "This will connect directly to that address. Use this only on a trusted LAN, VPN, or device you control."
        )
    }

    private var signedInAccountText: String {
        guard authManager.isAuthenticated else {
            return L10n.string(
                "mobile.addDevice.notSignedIn",
                defaultValue: "Not signed in on this device."
            )
        }
        guard let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return L10n.string(
                "mobile.addDevice.signedInUnknown",
                defaultValue: "Signed in, email unavailable."
            )
        }
        let format = L10n.string(
            "mobile.addDevice.signedInFormat",
            defaultValue: "Signed in as %@"
        )
        return String(format: format, email)
    }

    private func pair() {
        validationError = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        if CmxPairingURLScheme.hasPairingScheme(trimmedHost) {
            pairingCode = trimmedHost
            startPairingTask {
                await connectPairingCode()
            }
            return
        }
        guard MobileShellRouteAuthPolicy.normalizedManualHost(trimmedHost) != nil else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        guard let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(parsedPort) else {
            validationError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            return
        }

        startPairingTask {
            await connectManualHost(deviceName, trimmedHost, parsedPort)
        }
    }

    private func startPairingTask(_ operation: @escaping @MainActor () async -> Void) {
        pairingTask?.cancel()
        let taskID = UUID()
        pairingTaskID = taskID
        isPairing = true
        let task = Task { @MainActor in
            defer {
                if pairingTaskID == taskID {
                    isPairing = false
                    pairingTaskID = nil
                    pairingTask = nil
                }
            }
            await operation()
        }
        pairingTask = task
    }
}

private enum AddDeviceField: Hashable {
    case name
    case host
    case port
}
