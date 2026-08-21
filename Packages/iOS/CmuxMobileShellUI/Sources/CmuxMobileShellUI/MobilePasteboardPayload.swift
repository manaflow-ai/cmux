#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

enum MobilePasteboardPayload {
    case image(Data)
    case files([URL])
    case text(String)
}

struct MobilePasteboardReader {
    func payload(from pasteboard: UIPasteboard = .general) -> MobilePasteboardPayload? {
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

    func hasAttachmentPayload(in pasteboard: UIPasteboard = .general) -> Bool {
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
    /// through NSItemProvider. Materialize EVERY file provider's URL while its
    /// temporary security scope is valid — copying into an app-owned temp
    /// location that keeps the original file name — then hand the durable
    /// copies to the normal stager. The staging caller owns the copies and
    /// must release them with ``cleanUpMaterializedFiles(_:)`` once staged.
    /// - Returns: `true` when a load was started (the completion will fire),
    ///   `false` when the pasteboard offers nothing loadable.
    @discardableResult
    func loadAttachmentPayload(
        from pasteboard: UIPasteboard = .general,
        completion: @escaping @MainActor (MobilePasteboardPayload?) -> Void
    ) -> Bool {
        let providers = pasteboard.itemProviders
        // An image provider wins outright, matching the synchronous reader's
        // image-before-files ordering.
        if let imageProvider = providers.first(where: { provider in
            provider.registeredTypeIdentifiers.contains {
                UTType($0)?.conforms(to: .image) == true
            }
        }), let imageType = imageProvider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            imageProvider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                Task { @MainActor in completion(data.map(MobilePasteboardPayload.image)) }
            }
            return true
        }
        let fileProviders = providers.filter { provider in
            provider.registeredTypeIdentifiers.contains {
                $0 == UTType.fileURL.identifier || $0 == UTType.url.identifier
            }
        }
        guard !fileProviders.isEmpty else { return false }
        materializeFileProviders(fileProviders, into: []) { urls in
            completion(urls.isEmpty ? nil : .files(urls))
        }
        return true
    }

    /// Release copies produced by ``loadAttachmentPayload(from:completion:)``:
    /// each lives alone in an app-owned wrapper directory (which carries the
    /// uniqueness so the file keeps its original name), so the wrapper is
    /// removed with it. Foreign URLs are left untouched.
    func cleanUpMaterializedFiles(_ urls: [URL]) {
        for url in urls {
            let wrapper = url.deletingLastPathComponent()
            guard wrapper.lastPathComponent.hasPrefix(Self.materializedWrapperPrefix) else {
                continue
            }
            try? FileManager.default.removeItem(at: wrapper)
        }
    }

    private static let materializedWrapperPrefix = "cmux-pasted-file-"

    /// Copy each provider's file representation, one at a time (each copy must
    /// happen inside its provider's completion, while the temporary security
    /// scope is valid). A provider that fails to load or copy is skipped so one
    /// bad item cannot drop the rest of a multi-file paste.
    private func materializeFileProviders(
        _ providers: [NSItemProvider],
        into collected: [URL],
        completion: @escaping @MainActor ([URL]) -> Void
    ) {
        guard let provider = providers.first else {
            Task { @MainActor in completion(collected) }
            return
        }
        let remaining = Array(providers.dropFirst())
        guard let fileType = provider.registeredTypeIdentifiers.first(where: {
            $0 == UTType.fileURL.identifier || $0 == UTType.url.identifier
        }) else {
            materializeFileProviders(remaining, into: collected, completion: completion)
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: fileType) { url, _ in
            var next = collected
            if let url, let copied = copyIntoTemporaryStorage(url) {
                next.append(copied)
            }
            materializeFileProviders(remaining, into: next, completion: completion)
        }
    }

    /// Copy one provider-scoped file into `tmp/<unique wrapper>/<original name>`
    /// so the durable copy keeps the user-visible file name for the chip row
    /// and preview title.
    private func copyIntoTemporaryStorage(_ url: URL) -> URL? {
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Self.materializedWrapperPrefix + UUID().uuidString,
                isDirectory: true
            )
        let name = url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent
        let destination = wrapper.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: wrapper,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: wrapper)
            return nil
        }
    }
}
#endif
