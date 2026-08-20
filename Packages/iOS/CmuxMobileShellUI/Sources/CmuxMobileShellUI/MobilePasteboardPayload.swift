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
        case .text: false
        case nil:
            pasteboard.itemProviders.contains { provider in
                provider.registeredTypeIdentifiers.contains { identifier in
                    identifier == UTType.fileURL.identifier
                        || identifier == UTType.url.identifier
                        || UTType(identifier)?.conforms(to: .image) == true
                }
            }
        }
    }

    /// Files copied from Files.app and other providers are often exposed only
    /// through NSItemProvider. Materialize the provider URL while its temporary
    /// security scope is valid, then hand the durable copy to the normal stager.
    @discardableResult
    static func loadAttachmentPayload(
        from pasteboard: UIPasteboard = .general,
        completion: @escaping @MainActor (MobilePasteboardPayload?) -> Void
    ) -> Bool {
        guard let provider = pasteboard.itemProviders.first(where: { provider in
            provider.registeredTypeIdentifiers.contains { identifier in
                identifier == UTType.fileURL.identifier
                    || identifier == UTType.url.identifier
                    || identifier == UTType.image.identifier
                    || identifier == UTType.data.identifier
            }
        }) else {
            return false
        }

        if let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                Task { @MainActor in completion(data.map(MobilePasteboardPayload.image)) }
            }
            return true
        }

        guard let fileType = provider.registeredTypeIdentifiers.first(where: {
            $0 == UTType.fileURL.identifier || $0 == UTType.url.identifier
        }) else {
            return false
        }
        provider.loadFileRepresentation(forTypeIdentifier: fileType) { url, _ in
            guard let url else {
                Task { @MainActor in completion(nil) }
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                Task { @MainActor in completion(.files([destination])) }
            } catch {
                Task { @MainActor in completion(nil) }
            }
        }
        return true
    }
}
#endif
