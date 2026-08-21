#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers

/// One pasteboard item materialized into an app-owned temporary file, ready to
/// hand to a composer's stager. The file lives alone inside a uniquely named
/// wrapper directory (the wrapper carries the uniqueness so the file keeps its
/// user-visible name); the staging caller owns the copy and must release it
/// with ``MobilePasteboardReader/cleanUp(_:)`` once staged.
struct MobilePastedAttachment: Sendable {
    enum Kind: Sendable {
        case image
        case file
    }

    let kind: Kind
    /// App-owned temporary copy of the pasted bytes.
    let url: URL
    /// The user-visible name: the original file name when the provider carries
    /// one, otherwise a generated `pasted-image.<ext>` style fallback.
    let displayName: String
}

/// The single classification and materialization point for attachment pastes
/// in the task and terminal composers.
///
/// `hasAttachmentContent` is a cheap metadata probe (safe for
/// `canPerformAction`, it never reads pasteboard contents so it cannot trigger
/// the iOS paste privacy prompt). `materializeAttachments` performs the actual
/// read: every image or file item is copied into app-owned temporary storage
/// through its `NSItemProvider` — files copied from Files.app are often exposed
/// ONLY through providers, and a provider's file must be copied out inside its
/// load completion while the temporary security scope is valid.
struct MobilePasteboardReader: Sendable {
    /// Whether the pasteboard holds anything the composers stage as an
    /// attachment: an image, or a file-URL-backed item. Plain text and web
    /// URLs are NOT attachment content; they fall through to native paste.
    func hasAttachmentContent(in pasteboard: UIPasteboard) -> Bool {
        if pasteboard.hasImages { return true }
        return pasteboard.itemProviders.contains { provider in
            provider.registeredTypeIdentifiers.contains { identifier in
                identifier == UTType.fileURL.identifier
                    || UTType(identifier)?.conforms(to: .image) == true
            }
        }
    }

    /// Materialize every image and file item on the pasteboard into app-owned
    /// temporary copies, in item order. A provider that fails to load or copy
    /// is skipped so one bad item cannot drop the rest of a multi-item paste.
    func materializeAttachments(
        from pasteboard: UIPasteboard
    ) async -> [MobilePastedAttachment] {
        var results: [MobilePastedAttachment] = []
        let providers = pasteboard.itemProviders
        for provider in providers {
            if let imageType = registeredImageType(of: provider) {
                if let attachment = await materializeImage(
                    provider,
                    contentType: imageType
                ) {
                    results.append(attachment)
                }
            } else if provider.registeredTypeIdentifiers
                .contains(UTType.fileURL.identifier) {
                if let attachment = await materializeFile(provider) {
                    results.append(attachment)
                }
            }
        }
        // Some sources put an image on the pasteboard without a matching item
        // provider representation; fall back to the decoded image itself.
        if results.isEmpty, pasteboard.hasImages,
           let data = pasteboard.image?.pngData(),
           let url = writeIntoTemporaryStorage(data, name: "pasted-image.png") {
            results.append(MobilePastedAttachment(
                kind: .image,
                url: url,
                displayName: "pasted-image.png"
            ))
        }
        return results
    }

    /// Release copies produced by ``materializeAttachments(from:)``. Each file
    /// lives alone in an app-owned wrapper directory, so the wrapper is removed
    /// with it. Foreign URLs are left untouched.
    func cleanUp(_ attachments: [MobilePastedAttachment]) {
        for attachment in attachments {
            let wrapper = attachment.url.deletingLastPathComponent()
            guard wrapper.lastPathComponent.hasPrefix(Self.wrapperPrefix) else {
                continue
            }
            try? FileManager.default.removeItem(at: wrapper)
        }
    }

    private static let wrapperPrefix = "cmux-pasted-attachment-"

    /// The most specific registered raster type, so the copied file keeps a
    /// faithful extension (`png`/`jpeg`/`heic`) for the image preparer.
    private func registeredImageType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .image) }
    }

    private func materializeImage(
        _ provider: NSItemProvider,
        contentType: UTType
    ) async -> MobilePastedAttachment? {
        let suggestedName = provider.suggestedName
        let url: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: contentType.identifier
            ) { loaded, _ in
                // Copy inside the completion, while the provider-scoped temp
                // file is still valid.
                let name = imageFileName(
                    suggested: suggestedName,
                    loaded: loaded,
                    contentType: contentType
                )
                continuation.resume(
                    returning: loaded.flatMap {
                        copyIntoTemporaryStorage($0, name: name)
                    }
                )
            }
        }
        guard let url else { return nil }
        return MobilePastedAttachment(
            kind: .image,
            url: url,
            displayName: url.lastPathComponent
        )
    }

    private func materializeFile(
        _ provider: NSItemProvider
    ) async -> MobilePastedAttachment? {
        let url: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { loaded, _ in
                continuation.resume(
                    returning: loaded.flatMap {
                        copyIntoTemporaryStorage($0, name: $0.lastPathComponent)
                    }
                )
            }
        }
        guard let url else { return nil }
        return MobilePastedAttachment(
            kind: .file,
            url: url,
            displayName: url.lastPathComponent
        )
    }

    /// A user-presentable image file name whose extension matches the loaded
    /// representation: the provider's suggested name when present, else the
    /// loaded file's own name, else a `pasted-image` fallback.
    private func imageFileName(
        suggested: String?,
        loaded: URL?,
        contentType: UTType
    ) -> String {
        let ext = loaded?.pathExtension.isEmpty == false
            ? loaded!.pathExtension
            : (contentType.preferredFilenameExtension ?? "png")
        let stem: String
        if let suggested, !suggested.isEmpty {
            stem = (suggested as NSString).deletingPathExtension
        } else if let loadedName = loaded?.deletingPathExtension().lastPathComponent,
                  !loadedName.isEmpty {
            stem = loadedName
        } else {
            stem = "pasted-image"
        }
        return "\(stem).\(ext)"
    }

    /// Copy one provider-scoped file into `tmp/<unique wrapper>/<name>` so the
    /// durable copy keeps the user-visible file name for chips and previews.
    private func copyIntoTemporaryStorage(_ source: URL, name: String) -> URL? {
        let fileName = name.isEmpty ? UUID().uuidString : name
        guard let wrapper = makeWrapperDirectory() else { return nil }
        let destination = wrapper.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: wrapper)
            return nil
        }
    }

    private func writeIntoTemporaryStorage(_ data: Data, name: String) -> URL? {
        guard let wrapper = makeWrapperDirectory() else { return nil }
        let destination = wrapper.appendingPathComponent(name)
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: wrapper)
            return nil
        }
    }

    private func makeWrapperDirectory() -> URL? {
        let wrapper = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                Self.wrapperPrefix + UUID().uuidString,
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: wrapper,
                withIntermediateDirectories: true
            )
            return wrapper
        } catch {
            return nil
        }
    }
}
#endif
