#if os(iOS)
@preconcurrency import AVFoundation
import CmuxMobileDesign
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Settings → Devices → "Scan QR on your Mac": the camera reads the pairing
/// code cmux shows on the Mac and hands its text to `open`
/// (``SettingsDeviceDirectory/openPairingCode(_:)``).
struct PairCodeScannerSheet: View {
    /// Takes a scanned code's text; true when the app took it as a pairing code.
    let open: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    /// A code was read that is no live pairing code for this account.
    @State private var rejected = false

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .authorized:
                    PairCodeCameraView { code in
                        if open(code) { dismiss() } else { rejected = true }
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) { hint }
                case .notDetermined:
                    ProgressView()
                default:
                    ContentUnavailableView {
                        Label("Camera access is off", systemImage: "camera")
                    } description: {
                        Text("Allow cmux to use the camera in Settings to scan the code on your Mac.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            }
            .navigationTitle("Scan QR on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            guard access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private var hint: some View {
        Text(rejected
             ? "That isn't a pairing code for this account, or it expired. Show a new code on your Mac."
             : "Point the camera at the pairing code cmux shows on your Mac.")
            .font(theme.type.meta)
            .multilineTextAlignment(.center)
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
            .accessibilityIdentifier("settings.pairScanner.hint")
    }
}

/// The camera preview that reads QR codes (`AVCaptureMetadataOutput`).
struct PairCodeCameraView: UIViewRepresentable {
    let found: @MainActor (String) -> Void

    func makeCoordinator() -> PairCodeCamera { PairCodeCamera() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspectFill
        context.coordinator.found = found
        context.coordinator.start(preview: view.preview)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.found = found
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: PairCodeCamera) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer is one by `layerClass`.
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The capture session behind the scanner. `found` and `last` are touched on
/// the main queue only (the metadata delegate runs there); the session starts
/// and stops on `queue`. It stops when the sheet's view goes away.
final class PairCodeCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    // carve-out: `startRunning` blocks; Apple runs the session on its own serial queue.
    private let queue = DispatchQueue(label: "dev.cmux.mobile.pair-scanner")
    var found: (@MainActor (String) -> Void)?
    /// The last code read: the same code in the next frames is not handed on again.
    private var last: String?

    @MainActor func start(preview: AVCaptureVideoPreviewLayer) {
        // No camera (the Simulator): the preview stays dark.
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        preview.session = session
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            for code in codes where code != last {
                last = code
                found?(code)
            }
        }
    }
}
#endif
