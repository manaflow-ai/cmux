import CMUXMobileCore
import CmuxMobileCamera
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import AVFoundation
import UIKit
#endif

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void
    let onCancel: (() -> Void)?
    let onEnterManually: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileDiagnosticLog) private var diagnosticLog
    private let authorization: CameraAuthorization
    private let previewEnabled: Bool
    @State private var authorizationStatus: AVAuthorizationStatus

    init(
        previewEnabled: Bool = false,
        onCancel: (() -> Void)? = nil,
        onEnterManually: (() -> Void)? = nil,
        onCode: @escaping (String) -> Void
    ) {
        let authorization = CameraAuthorization()
        self.authorization = authorization
        self.previewEnabled = previewEnabled
        self.onCancel = onCancel
        self.onEnterManually = onEnterManually
        self.onCode = onCode
        _authorizationStatus = State(
            initialValue: previewEnabled ? .authorized : authorization.videoStatus
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if previewEnabled {
                    MobilePairingScannerPreview()
                } else {
                    switch authorizationStatus {
                    case .authorized:
                        ZStack(alignment: .bottom) {
                            QRCodeScannerView(
                                onCode: { code in
                                    diagnosticLog?.recordAppEvent(.qrScanSucceeded)
                                    dismiss()
                                    onCode(code)
                                },
                                onUnavailable: {
                                    diagnosticLog?.recordAppEvent(
                                        .qrScanFailed,
                                        failure: .endpointUnavailable
                                    )
                                }
                            )
                            .ignoresSafeArea(edges: .bottom)

                            Text(Self.guidanceText)
                                .font(.footnote.weight(.medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    .black.opacity(0.72),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .padding(16)
                                .accessibilityIdentifier("MobilePairingScannerGuidance")
                        }
                    case .notDetermined:
                        ProgressView()
                            .accessibilityIdentifier("MobilePairingScannerPermissionProgress")
                            .task {
                                diagnosticLog?.recordAppEvent(.cameraAuthorizationRequested)
                                authorizationStatus = await authorization.requestVideoAccess()
                            }
                    case .denied:
                        ContentUnavailableView {
                            Label(
                                L10n.string(
                                    "mobile.pairing.cameraDenied",
                                    defaultValue: "Camera Access Required"
                                ),
                                systemImage: "camera.fill"
                            )
                        } description: {
                            Text(L10n.string(
                                "mobile.pairing.cameraDeniedDescription",
                                defaultValue: "Allow camera access in Settings to scan the QR code from your Mac."
                            ))
                        } actions: {
                            Button {
                                openSettings()
                            } label: {
                                Text(L10n.string(
                                    "mobile.pairing.openSettings",
                                    defaultValue: "Open Settings"
                                ))
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("MobilePairingOpenSettingsButton")
                            manualEntryButton
                        }
                        .accessibilityIdentifier("MobilePairingCameraDenied")
                    case .restricted:
                        ContentUnavailableView {
                            Label(
                                L10n.string(
                                    "mobile.pairing.cameraDenied",
                                    defaultValue: "Camera Access Required"
                                ),
                                systemImage: "camera.fill"
                            )
                        } description: {
                            Text(L10n.string(
                                "mobile.pairing.cameraRestrictedDescription",
                                defaultValue: """
                                Camera access is restricted on this device. Use a pairing link or the manual form instead.
                                """
                            ))
                        } actions: { manualEntryButton }
                        .accessibilityIdentifier("MobilePairingCameraRestricted")
                    @unknown default:
                        ContentUnavailableView {
                            Label(
                                L10n.string(
                                    "mobile.pairing.cameraUnavailable",
                                    defaultValue: "Camera Unavailable"
                                ),
                                systemImage: "camera.fill"
                            )
                        } actions: { manualEntryButton }
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        diagnosticLog?.recordAppEvent(.qrScanCancelled, failure: .cancelled)
                        dismiss()
                        onCancel?()
                    } label: {
                        Text(L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"))
                    }
                    .accessibilityIdentifier("MobileScannerCancelButton")
                }
            }
        }
        .accessibilityIdentifier("MobilePairingScannerSheet")
        .onAppear {
            diagnosticLog?.recordAppEvent(.qrScanStarted)
        }
        .onChange(of: authorizationStatus, initial: true) { _, status in
            switch status {
            case .authorized:
                diagnosticLog?.recordAppEvent(.cameraAuthorizationGranted)
            case .denied, .restricted:
                diagnosticLog?.recordAppEvent(
                    .cameraAuthorizationDenied,
                    failure: .permissionDenied
                )
            case .notDetermined:
                break
            @unknown default:
                diagnosticLog?.recordAppEvent(
                    .cameraAuthorizationDenied,
                    failure: .unknown
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !previewEnabled else { return }
            authorizationStatus = authorization.videoStatus
        }
    }

    @ViewBuilder
    private var manualEntryButton: some View {
        if let onEnterManually {
            Button {
                diagnosticLog?.recordAppEvent(.qrScanCancelled, failure: .cancelled)
                dismiss()
                onEnterManually()
            } label: {
                Text(L10n.string("mobile.pairing.enterManually", defaultValue: "Enter Manually"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobilePairingEnterManuallyButton")
        }
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
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

extension MobilePairingScannerSheet {
    /// The localized Tailscale setup sequence shared by every pairing
    /// entrypoint. Version-free on purpose: the per-0.64.17 steps described a
    /// Mac below the pairing floor (MobileMacPairingFloor), which this build
    /// no longer dials.
    static var guidanceText: String {
        L10n.string(
            "mobile.tailscalePairing.instructions",
            defaultValue: """
            Install Tailscale on both devices and use the same Tailscale network, then open \
            Tailscale Pairing on the Mac and scan its code here.
            """
        )
    }

    /// Tailscale setup guidance for an empty computer list, including the route back to Auto-Connect.
    static var emptyStateGuidanceText: String {
        L10n.string(
            "mobile.tailscalePairing.emptyDescription",
            defaultValue: """
            Install Tailscale on both devices and use the same Tailscale network, then open \
            Tailscale Pairing on the Mac and scan its code here. To use Auto-Connect instead, \
            open Settings, tap Connection Method, and choose Auto-Connect.
            """
        )
    }
}
