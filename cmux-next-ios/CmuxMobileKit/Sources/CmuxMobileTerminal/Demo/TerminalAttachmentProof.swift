#if os(iOS) && DEBUG
import CmuxMobileLinkFFI
import Foundation
import UIKit

extension TerminalModel {
    public func demoAttachmentProgress(_ attachment: ComposerAttachment) -> UploadProgress? {
        uploadProgress(attachment)
    }

    /// The real Photos completion path, with deterministic bytes instead of a library picker.
    /// The live-link rig retains these bytes to check that encoding never mutates the pick.
    public func demoPickAttachmentImage() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).image { context in
            for y in stride(from: 0, to: 3072, by: 32) {
                for x in stride(from: 0, to: 4096, by: 32) {
                    UIColor(hue: CGFloat((x * 7 + y * 11) % 255) / 255,
                            saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 32, height: 32))
                }
            }
        }
        guard let data = image.jpegData(compressionQuality: 1) else { return nil }
        let tile = ComposerAttachment(kind: .image, name: "attachment-proof.jpg", isLoading: true)
        loadPickedAttachment(tile) { .image(data, thumbnail: nil) }
        return data
    }
}
#endif
