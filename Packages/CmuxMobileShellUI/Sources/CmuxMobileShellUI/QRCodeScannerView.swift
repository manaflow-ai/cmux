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

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> QRCodeCaptureController {
        let stream = QRCodeScanStream()
        context.coordinator.observe(stream: stream)
        return QRCodeCaptureController(
            stream: stream,
            accepts: MobilePairingScannerPolicy.acceptsCode,
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
#endif
