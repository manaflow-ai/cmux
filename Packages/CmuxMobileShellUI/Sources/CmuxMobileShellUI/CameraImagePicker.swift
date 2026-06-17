#if os(iOS)
import SwiftUI
import UIKit

/// A minimal camera capture sheet for composer attachments.
///
/// Wraps `UIImagePickerController` with `sourceType = .camera` (PhotosUI's
/// `PhotosPicker` cannot capture from the camera) and hands the captured photo
/// back as JPEG `Data`, or `nil` if the user cancels. Camera authorization is
/// requested by the system on first presentation, so the prompt is gated to the
/// moment the user picks "Camera" from the attach menu.
struct CameraImagePicker: UIViewControllerRepresentable {
    /// Receives the captured photo as JPEG bytes, or `nil` on cancel. Called once.
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
