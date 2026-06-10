import CmuxMobileWorkspace
import CmuxMobileCamera
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// SwiftUI host for the ``CmuxMobileCamera`` QR-capture controller.
///
/// Owns one ``QRCodeScanStream`` per presentation, mounts the package's
/// ``QRCodeCaptureController``, and forwards accepted `cmux-ios://` codes to
/// `onCode`. The AVCaptureSession lifecycle now lives entirely in the camera
/// service; this wrapper only bridges the stream to a SwiftUI callback.
struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    /// Called once per distinct decoded QR that is not a cmux pairing code, so
    /// the scanner UI can explain why nothing happened. Optional: omitting it
    /// keeps the old silently-ignore behavior.
    var onNonPairingCode: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onNonPairingCode: onNonPairingCode)
    }

    func makeUIViewController(context: Context) -> QRCodeCaptureController {
        let stream = QRCodeScanStream()
        let coordinator = context.coordinator
        coordinator.observe(stream: stream)
        return QRCodeCaptureController(
            stream: stream,
            accepts: MobilePairingScannerPolicy.acceptsCode,
            unavailableText: L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
            onRejectedCode: { _ in coordinator.onNonPairingCode?() }
        )
    }

    func updateUIViewController(_ uiViewController: QRCodeCaptureController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onNonPairingCode = onNonPairingCode
    }

    static func dismantleUIViewController(_ uiViewController: QRCodeCaptureController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        var onCode: (String) -> Void
        var onNonPairingCode: (() -> Void)?
        private var task: Task<Void, Never>?

        init(onCode: @escaping (String) -> Void, onNonPairingCode: (() -> Void)?) {
            self.onCode = onCode
            self.onNonPairingCode = onNonPairingCode
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
#endif
