import Foundation
@preconcurrency import AVFoundation
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileCamera
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import Observation
import OSLog
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
    let connectPairingCode: () async -> Void
    let connectManualHost: (String, String, Int) async -> Void
    let cancelPairing: () -> Void
    let cancel: () -> Void
    @State private var isShowingScanner = false
    @State private var deviceName = UITestConfig.addDeviceName
        ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac")
    @State private var host = UITestConfig.addDeviceHost ?? ""
    @State private var port = UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)"
    @Environment(AuthCoordinator.self) private var authManager
    @State private var validationError: String?
    @State private var isPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: AddDeviceField?

    var body: some View {
        NavigationStack {
            Form {
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
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                } footer: {
                    Text(L10n.string("mobile.addDevice.help", defaultValue: "Enter a Tailscale, LAN, or local host and port. QR/link pairing from that computer is still the safest setup path."))
                }
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    if UITestConfig.mockDataEnabled {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.string("mobile.addDevice.formAccessibilityLabel", defaultValue: "Add device form"))
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

                if let errorText {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorText)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("MobilePairingError")
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
            .navigationTitle(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
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

    private var manualRouteWarningText: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              !trimmedHost.hasPrefix("cmux-ios://"),
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
        if trimmedHost.hasPrefix("cmux-ios://") {
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

enum AddDeviceInputKind {
    case text
    case url
    case number
}

/// Whether a scanned QR payload is a cmux pairing link.
///
/// cmux pairing QR codes carry a `cmux-ios://` deep link; any other QR content
/// (a website URL, a Wi-Fi join code) must be ignored so the scanner never hands
/// the connection layer a non-pairing string.
func mobilePairingScannerAcceptsCode(_ code: String) -> Bool {
    code.hasPrefix("cmux-ios://")
}

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let authorization = CameraAuthorization()
    @State private var authorizationStatus = CameraAuthorization().videoStatus

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    QRCodeScannerView { code in
                        onCode(code)
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .notDetermined:
                    ProgressView()
                        .task {
                            authorizationStatus = await authorization.requestVideoAccess()
                        }
                case .denied, .restricted:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                        systemImage: "camera.fill"
                    )
                @unknown default:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                        systemImage: "camera.fill"
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"))
                    }
                    .accessibilityIdentifier("MobileScannerCancelButton")
                }
            }
        }
    }
}

/// SwiftUI host for the ``CmuxMobileCamera`` QR-capture controller.
///
/// Owns one ``QRCodeScanStream`` per presentation, mounts the package's
/// ``QRCodeCaptureController``, and forwards accepted `cmux-ios://` codes to
/// `onCode`. The AVCaptureSession lifecycle now lives entirely in the camera
/// service; this wrapper only bridges the stream to a SwiftUI callback.
struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> QRCodeCaptureController {
        let stream = QRCodeScanStream()
        context.coordinator.observe(stream: stream)
        return QRCodeCaptureController(
            stream: stream,
            accepts: mobilePairingScannerAcceptsCode,
            unavailableText: L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable")
        )
    }

    func updateUIViewController(_ uiViewController: QRCodeCaptureController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ uiViewController: QRCodeCaptureController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        var onCode: (String) -> Void
        private var task: Task<Void, Never>?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func observe(stream: QRCodeScanStream) {
            task?.cancel()
            task = Task { @MainActor [weak self] in
                for await code in stream.codes {
                    guard !Task.isCancelled else { return }
                    self?.onCode(code)
                }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}
#else
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void

    var body: some View {
        ContentUnavailableView(
            L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
            systemImage: "camera.fill"
        )
    }
}
#endif
