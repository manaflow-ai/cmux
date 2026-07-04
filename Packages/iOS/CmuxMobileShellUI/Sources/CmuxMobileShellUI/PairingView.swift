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
    let connectionError: String?
    /// A shorter, actionable next-step line shown beneath ``connectionError``
    /// (for example "Check that both devices are on the same Tailscale"). `nil`
    /// when the headline is already the full instruction.
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
    @State private var address = UITestConfig.addDeviceAddress ?? ""
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
                        L10n.string("mobile.addDevice.addressPlaceholder", defaultValue: "your-mac.tailnet.ts.net:58465"),
                        text: $address
                    )
                    .focused($focusedField, equals: .address)
                    .submitLabel(.done)
                    .addDeviceInputBehavior(.url)
                    .accessibilityIdentifier("MobileAddDeviceAddressField")
                } header: {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
                } footer: {
                    Text(L10n.string("mobile.addDevice.help", defaultValue: "Paste the address from the Mac's pairing window (Copy Address). The port is optional. QR/link pairing from that computer is still the safest setup path."))
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

                if let errorText {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorText)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("MobilePairingError")
                            if let guidanceText = errorGuidanceText {
                                Text(guidanceText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("MobilePairingErrorGuidance")
                            }
                            Text(signedInAccountText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobilePairingErrorSignedInAccount")
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
                .disabled(isPairing || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var errorText: String? {
        validationError ?? connectionError
    }

    /// The guidance line only belongs to a connection error. A local validation
    /// error (bad host/port) is self-explanatory and has no store-side guidance,
    /// so suppress the connection guidance while a validation error is showing.
    private var errorGuidanceText: String? {
        guard validationError == nil else { return nil }
        return connectionErrorGuidance
    }

    private var manualRouteWarningText: String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty,
              !CmxPairingURLScheme.hasPairingScheme(trimmedAddress),
              case .success(let entry) = CmxManualPairingEntry.parse(trimmedAddress, defaultPort: CmxMobileDefaults.defaultHostPort),
              MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning(entry.host) else {
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
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        if CmxPairingURLScheme.hasPairingScheme(trimmedAddress) {
            pairingCode = trimmedAddress
            startPairingTask {
                await connectPairingCode()
            }
            return
        }
        let entry: CmxManualPairingEntry
        switch CmxManualPairingEntry.parse(trimmedAddress, defaultPort: CmxMobileDefaults.defaultHostPort) {
        case .success(let parsed):
            entry = parsed
        case .failure(.invalidHost):
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        case .failure(.invalidPort):
            validationError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            return
        }
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(entry.host) else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }

        startPairingTask {
            await connectManualHost(deviceName, normalizedHost, entry.port)
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
    case address
}
