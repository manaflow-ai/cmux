#if os(iOS) && DEBUG
import CmuxMobileSupport
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// App-owned attachment files used only by deterministic accessibility hosts.
struct MobileAttachmentAccessibilityFixtures {
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-attachment-accessibility-fixtures", isDirectory: true),
        fileManager: FileManager = FileManager()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func basic() -> [MobileStagedAttachment] {
        let imageData = distinctiveImageData()
        let fileData = Data("attachment fixture".utf8)
        return [
            make(
                id: "D3B510CE-D56A-41D3-91CE-1E7056CD1742",
                kind: .image,
                fileName: "設計 🖼️.png",
                storedName: "preview.png",
                data: imageData,
                thumbnailData: imageData
            ),
            make(
                id: "812E3740-6EA3-490C-B025-84451A13579D",
                kind: .file,
                fileName: "-release notes.txt",
                storedName: "preview.txt",
                data: fileData
            ),
        ]
    }

    func edgeCases() -> [MobileStagedAttachment] {
        [
            make(
                id: "18349618-77EF-42C6-8E90-4C1D10DDB6CE",
                kind: .file,
                fileName: "empty file.txt",
                storedName: "empty.txt",
                data: Data()
            ),
            make(
                id: "E22DDCE5-44D0-4300-B749-81D531FA1D66",
                kind: .file,
                fileName: "unsupported.cmuxfixture",
                storedName: "unsupported.cmuxfixture",
                data: Data("unsupported fixture".utf8)
            ),
        ]
    }

    func overflow() -> [MobileStagedAttachment] {
        basic() + edgeCases()
    }

    func maximumCount() -> [MobileStagedAttachment] {
        (0..<MobileStagedAttachment.maximumCount).map { index in
            let suffix = String(format: "%02d", index + 1)
            return make(
                id: String(format: "00000000-0000-4000-8000-%012d", index + 1),
                kind: .file,
                fileName: "fixture-\(suffix).txt",
                storedName: "fixture-\(suffix).txt",
                data: Data("fixture \(suffix)".utf8)
            )
        }
    }

    func delayedResult() -> MobileStagedAttachment {
        make(
            id: "5C5E03D9-8776-4EB1-A975-C58A6CB0A75C",
            kind: .file,
            fileName: "late-result.txt",
            storedName: "late-result.txt",
            data: Data("late attachment result".utf8)
        )
    }

    func orientedLargeImage() -> MobileStagedAttachment {
        let data = orientedLargeImageData()
        return make(
            id: "8E691F0D-C965-4E05-9F08-D7135ADCC2D0",
            kind: .image,
            fileName: "oriented-large.jpg",
            storedName: "oriented-large.jpg",
            data: data,
            thumbnailData: distinctiveImageData()
        )
    }

    private func make(
        id: String,
        kind: MobileStagedAttachment.Kind,
        fileName: String,
        storedName: String,
        data: Data,
        thumbnailData: Data? = nil
    ) -> MobileStagedAttachment {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent(storedName)
        try? data.write(to: url, options: .atomic)
        return MobileStagedAttachment(
            id: UUID(uuidString: id)!,
            kind: kind,
            fileName: fileName,
            localFileURL: url,
            byteCount: data.count,
            thumbnailData: thumbnailData
        )
    }

    private func distinctiveImageData() -> Data {
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor(
                red: 0.08,
                green: 0.32,
                blue: 0.88,
                alpha: 1
            ).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(UIColor(
                red: 1,
                green: 0.78,
                blue: 0.08,
                alpha: 1
            ).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            context.fill(CGRect(x: 48, y: 48, width: 48, height: 48))
        }
    }

    private func orientedLargeImageData() -> Data {
        let width = 6_000
        let height = 3_000
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return Data() }
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.systemYellow.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { return Data() }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return Data() }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.82,
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFOrientation: CGImagePropertyOrientation.right.rawValue,
                ] as CFDictionary,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return Data() }
        let imageData = data as Data
        assert(hasExpectedOrientationMetadata(in: imageData, width: width, height: height))
        return imageData
    }

    private func hasExpectedOrientationMetadata(in data: Data, width: Int, height: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let copiedProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
            return false
        }
        let properties = copiedProperties as NSDictionary
        guard let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary else {
            return false
        }
        let expectedOrientation = Int(CGImagePropertyOrientation.right.rawValue)
        return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width
            && (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height
            && (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == expectedOrientation
            && (tiffProperties[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
                == expectedOrientation
    }
}
#endif
