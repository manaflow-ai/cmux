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
    let initialPresentation: PairingPresentation
    let connectionError: String?
    /// A shorter, actionable next-step line shown beneath ``connectionError``
    /// (for example "Check that the selected private route is active"). `nil`
    /// when the headline is already the full instruction.
    let connectionErrorGuidance: String?
    let versionWarning: String?
    let connectPairingCode: () async -> MobilePairingURLConnectionResult
    let acceptVersionWarning: () async -> MobilePairingURLConnectionResult
    let connectManualHost: (String, String, Int) async -> MobilePairingURLConnectionResult
    let cancelPairing: () -> Void
    let cancel: () -> Void
    /// Called exactly once after a pairing operation reports semantic success.
    /// Presentation owners use this signal instead of observing a connection
    /// state edge, which can remain `.connected` when adding another Mac.
    let onPairingSucceeded: () -> Void

    @State private var isShowingScanner: Bool
    @State private var deviceName = UITestConfig.addDeviceName
        ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac")
    @State private var host = UITestConfig.addDeviceHost ?? ""
    @State private var port = UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)"
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @State private var validationError: String?
    @State private var isPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: AddDeviceField?

    init(
        pairingCode: Binding<String>,
        initialPresentation: PairingPresentation = .manual,
        connectionError: String?,
        connectionErrorGuidance: String?,
        versionWarning: String?,
        connectPairingCode: @escaping () async -> MobilePairingURLConnectionResult,
        acceptVersionWarning: @escaping () async -> MobilePairingURLConnectionResult,
        connectManualHost: @escaping (String, String, Int) async -> MobilePairingURLConnectionResult,
        cancelPairing: @escaping () -> Void,
        cancel: @escaping () -> Void,
        onPairingSucceeded: @escaping () -> Void = {}
    ) {
        _pairingCode = pairingCode
        self.initialPresentation = initialPresentation
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.versionWarning = versionWarning
        self.connectPairingCode = connectPairingCode
        self.acceptVersionWarning = acceptVersionWarning
        self.connectManualHost = connectManualHost
        self.cancelPairing = cancelPairing
        self.cancel = cancel
        self.onPairingSucceeded = onPairingSucceeded
        _isShowingScanner = State(initialValue: initialPresentation.showsScanner)
    }

    var body: some View {
        NavigationStack {
            Form {
                if initialPresentation.showsManualPairingControls {
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
                            L10n.string(
                                "mobile.addDevice.hostPlaceholder",
                                defaultValue: "Tailscale IP, MagicDNS name, or LAN host"
                            ),
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
                        Text(L10n.string("mobile.connections.add", defaultValue: "Add Computer"))
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MobilePairingScannerSheet.guidanceText)
                            Text(L10n.string(
                                "mobile.addDevice.help",
                                defaultValue: "Scan the Mac's pairing QR, or enter a Tailscale IP, MagicDNS name, or local-network host and port. The entered destination is authorized only for this pairing. In the Simulator, 127.0.0.1 can connect to a local Mac."
                            ))
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        #if DEBUG
                        if UITestConfig.mockDataEnabled {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(L10n.string("mobile.connections.addFormAccessibilityLabel", defaultValue: "Add Computer form"))
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

                                Text(L10n.string("mobile.addDevice.accountHelp", defaultValue: "Pairing uses this account. If it does not match the Mac, sign in to the same account, then scan the Mac QR or enter its Tailscale, MagicDNS, or local-network address."))
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
                if initialPresentation.showsManualPairingControls {
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
            }
            .navigationTitle(navigationTitle)
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
        .accessibilityIdentifier("MobilePairingView")
        #if os(iOS)
        .sheet(isPresented: $isShowingScanner) {
            scannerSheet
        }
        .onAppear {
            analytics.capture(
                "ios_pairing_screen_viewed",
                ["entry": .string(initialPresentation.analyticsEntry)]
            )
        }
        .onChange(of: initialPresentation) { _, presentation in
            if isPairing {
                cancelActivePairingTask()
                cancelPairing()
            }
            isShowingScanner = presentation.showsScanner
            analytics.capture(
                "ios_pairing_screen_viewed",
                ["entry": .string(presentation.analyticsEntry)]
            )
        }
        #endif
    }

    private var navigationTitle: String {
        if initialPresentation == .tailscaleSetup {
            return L10n.string(
                "mobile.connections.tailscale.add",
                defaultValue: "Add Tailscale Connection"
            )
        }
        if initialPresentation.showsManualPairingControls {
            return L10n.string("mobile.connections.add", defaultValue: "Add Computer")
        }
        return L10n.string(
            "mobile.pairing.versionWarningTitle",
            defaultValue: "Compatibility mismatch"
        )
    }

    private var cancelButton: some View {
        Button {
            cancelActivePairingTask()
            cancelPairing()
            cancel()
        } label: {
            Text(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
        }
        .accessibilityIdentifier("MobilePairingCancelButton")
    }

    private func cancelActivePairingTask() {
        pairingTask?.cancel()
        pairingTaskID = nil
        pairingTask = nil
        isPairing = false
    }

    #if os(iOS)
    private var scannerSheet: some View {
        MobilePairingScannerSheet(
            previewEnabled: scannerPreviewEnabled,
            onCancel: scannerCancelAction,
            onEnterManually: scannerManualEntryAction
        ) { scannedCode in
            pairingCode = scannedCode
            isShowingScanner = false
            startPairingTask {
                await connectPairingCode()
            }
        }
    }

    private var scannerCancelAction: (() -> Void)? {
        guard initialPresentation.showsScanner else { return nil }
        return { cancelDirectScanner() }
    }

    private var scannerManualEntryAction: (() -> Void)? {
        guard initialPresentation.showsScanner else { return nil }
        return { isShowingScanner = false }
    }

    private var scannerPreviewEnabled: Bool {
        #if DEBUG
        return UITestConfig.pairingScannerPreviewEnabled
        #else
        return false
        #endif
    }
    #endif

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
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              CmxPairingURLScheme(urlString: trimmedHost) == nil,
              MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning(trimmedHost) else {
            return nil
        }
        return L10n.string(
            "mobile.addDevice.manualRouteWarning",
            defaultValue: "This address is authorized only for this pairing and uses an unencrypted connection. Verify it belongs to your Mac and that you trust the network before continuing; local-network hosts are not protected by Tailscale."
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
        if CmxPairingURLScheme(urlString: trimmedHost) != nil {
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

    private func startPairingTask(
        _ operation: @escaping @MainActor () async -> MobilePairingURLConnectionResult
    ) {
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
            let result = await operation()
            if !Task.isCancelled, pairingTaskID == taskID, result == .connected {
                onPairingSucceeded()
            }
        }
        pairingTask = task
    }

    private func cancelDirectScanner() {
        cancel()
    }
}

private enum AddDeviceField: Hashable {
    case name
    case host
    case port
}
