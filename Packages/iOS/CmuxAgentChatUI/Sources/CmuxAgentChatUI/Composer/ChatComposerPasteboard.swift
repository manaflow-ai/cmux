#if os(iOS)
import CmuxAgentChat
import Foundation
import SwiftUI
import UIKit

enum ChatComposerImageEncoder {
    static func attachment(
        id: String,
        data: Data,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        return attachment(
            id: id,
            image: image,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
    }

    static func attachment(
        id: String,
        image: UIImage,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard let jpeg = downscaledJPEG(
            from: image,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        ),
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

    private static func downscaledJPEG(
        from image: UIImage,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension else {
            return image.jpegData(compressionQuality: jpegQuality)
        }
        let scale = maxDimension / longest
        let targetSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}

enum ChatComposerPasteboard {
    static func attachment(
        from pasteboard: UIPasteboard,
        maxDimension: CGFloat,
        jpegQuality: CGFloat
    ) -> ChatComposerAttachment? {
        guard pasteboard.hasImages, let image = pasteboard.image else {
            return nil
        }
        return ChatComposerImageEncoder.attachment(
            id: "pasted-\(UUID().uuidString)",
            image: image,
            maxDimension: maxDimension,
            jpegQuality: jpegQuality
        )
    }

    static func text(from pasteboard: UIPasteboard) -> String? {
        guard pasteboard.hasStrings,
              let string = pasteboard.string,
              !string.isEmpty
        else {
            return nil
        }
        return string
    }
}
#endif
