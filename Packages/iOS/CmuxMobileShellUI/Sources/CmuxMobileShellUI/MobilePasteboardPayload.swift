#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum MobilePasteboardPayload {
    case image(Data)
    case files([URL])
    case text(String)
}

enum MobilePasteboardReader {
    static func payload(from pasteboard: UIPasteboard = .general) -> MobilePasteboardPayload? {
        for type in [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier] {
            if let data = pasteboard.data(forPasteboardType: type) {
                return .image(data)
            }
        }
        if let image = pasteboard.image, let data = image.pngData() {
            return .image(data)
        }
        let files = (pasteboard.urls ?? []).filter(\.isFileURL)
        if !files.isEmpty {
            return .files(files)
        }
        guard let text = pasteboard.string, !text.isEmpty else { return nil }
        return .text(text)
    }

    static func hasAttachmentPayload(in pasteboard: UIPasteboard = .general) -> Bool {
        switch payload(from: pasteboard) {
        case .image, .files: true
        case .text, nil: false
        }
    }
}
#endif
