#if os(iOS)
import CmuxAgentChat
import Foundation
import SwiftUI
import UIKit

extension Data {
    func chatComposerImageAttachment(
        id: String,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard let image = UIImage(data: self) else { return nil }
        return image.chatComposerAttachment(
            id: id,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
    }
}

extension UIImage {
    func chatComposerAttachment(
        id: String,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard let jpeg = chatComposerDownscaledJPEG(maxDimension: maxDimension, jpegQuality: jpegQuality),
              let thumbnailImage = UIImage(data: jpeg)
        else {
            return nil
        }
        return ChatComposerAttachment(
            id: id,
            data: jpeg,
            format: .jpeg,
            thumbnail: Image(uiImage: thumbnailImage)
        )
    }

    private func chatComposerDownscaledJPEG(
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> Data? {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension else {
            return jpegData(compressionQuality: jpegQuality)
        }
        let scale = maxDimension / longest
        let targetSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}

extension UIPasteboard {
    func chatComposerAttachment(
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard hasImages, let image else {
            return nil
        }
        return image.chatComposerAttachment(
            id: "pasted-\(UUID().uuidString)",
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
    }

    func chatComposerText() -> String? {
        guard hasStrings,
              let string,
              !string.isEmpty
        else {
            return nil
        }
        return string
    }
}
#endif
