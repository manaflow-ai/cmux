import CmuxMobileCamera
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let authorization = CameraAuthorization()
    @State private var authorizationStatus = CameraAuthorization().videoStatus
    /// Set when the camera decoded a QR that is not a cmux pairing code, so
    /// the sheet explains what to scan instead of silently doing nothing.
    @State private var didScanNonPairingCode = false

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    QRCodeScannerView(
                        onCode: { code in
                            onCode(code)
                        },
                        onNonPairingCode: {
                            didScanNonPairingCode = true
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom) {
                        if didScanNonPairingCode {
                            nonPairingCodeHint
                        }
                    }
                    .animation(.default, value: didScanNonPairingCode)
                case .notDetermined:
                    ProgressView()
                        .task {
                            authorizationStatus = await authorization.requestVideoAccess()
                        }
                case .denied, .restricted:
                    cameraDeniedView
                @unknown default:
                    ContentUnavailableView(
                        L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
                        systemImage: "camera.fill"
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code"))
            .navigationBarTitleDisplayMode(.inline)
            // Re-read camera authorization when the user comes back from
            // Settings (the denied walk-through's Open Settings round trip), so
            // a fresh grant flips this sheet to the scanner without reopening.
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active, authorizationStatus != .notDetermined else { return }
                authorizationStatus = authorization.videoStatus
            }
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

    /// Walk-through for a denied/restricted camera: name the problem, the
    /// recovery (the per-app Settings page), and a button that opens it.
    private var cameraDeniedView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.pairing.cameraDenied", defaultValue: "Camera Access Required"),
                systemImage: "camera.fill"
            )
        } description: {
            Text(L10n.string(
                "mobile.pairing.cameraDeniedHelp",
                defaultValue: "cmux needs the camera to scan the pairing code from your Mac. Allow Camera for cmux in Settings, then come back and scan again."
            ))
        } actions: {
            Button {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    openURL(settingsURL)
                }
            } label: {
                Text(L10n.string("mobile.pairing.openSettings", defaultValue: "Open Settings"))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobileScannerOpenSettingsButton")
        }
    }

    /// Hint shown after the camera decoded a QR that is not a cmux pairing
    /// code (a website QR, a Wi-Fi code): say what was wrong and where the
    /// real pairing code lives.
    private var nonPairingCodeHint: some View {
        Label {
            Text(L10n.string(
                "mobile.pairing.notPairingQR",
                defaultValue: "That QR code isn't a cmux pairing code. On your Mac, open cmux Settings > Mobile to show the pairing code, then scan that."
            ))
            .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("MobileScannerNonPairingHint")
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
