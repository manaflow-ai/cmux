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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let authorization: CameraAuthorization
    private let previewEnabled: Bool
    @State private var authorizationStatus: AVAuthorizationStatus

    init(
        previewEnabled: Bool = UITestConfig.pairingScannerPreviewEnabled,
        onCancel: (() -> Void)? = nil,
        onCode: @escaping (String) -> Void
    ) {
        let authorization = CameraAuthorization()
        self.authorization = authorization
        self.previewEnabled = previewEnabled
        self.onCancel = onCancel
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
                        QRCodeScannerView { code in
                            dismiss()
                            onCode(code)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    case .notDetermined:
                        ProgressView()
                            .accessibilityIdentifier("MobilePairingScannerPermissionProgress")
                            .task {
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
                        }
                        .accessibilityIdentifier("MobilePairingCameraRestricted")
                    @unknown default:
                        ContentUnavailableView(
                            L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                            systemImage: "camera.fill"
                        )
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
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
