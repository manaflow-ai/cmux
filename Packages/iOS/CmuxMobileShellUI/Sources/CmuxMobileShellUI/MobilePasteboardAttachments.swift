#if os(iOS)
import CmuxMobileDiagnostics
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
    /// How one pasteboard item should be staged, resolved from the provider's
    /// registered type identifiers ONLY (metadata, never content):
    /// - an image flavor stages as an image;
    /// - a `public.file-url` flavor stages as a file loaded through the URL;
    /// - a concrete document payload (pdf, zip, movie, …) with NO text or
    ///   web-URL flavor stages as a file loaded through that type — Files.app
    ///   exposes copied documents this way, registering the file's own content
    ///   type rather than `public.file-url`;
    /// - anything carrying a text or web-URL flavor is NOT attachment content,
    ///   so rich text, plain text, and links keep native text paste.
    enum ItemClassification {
        case image(loadAs: UTType)
        case file(loadAs: UTType)
    }

    /// Whether the pasteboard holds anything the composers stage as an
    /// attachment. Metadata-only; logs the per-item type identifiers to the
    /// debug log so a miss is diagnosable from a dogfood device.
    func hasAttachmentContent(in pasteboard: UIPasteboard) -> Bool {
        let providers = pasteboard.itemProviders
        let matched = pasteboard.hasImages
            || providers.contains { classification(of: $0) != nil }
            // Some sources register a file URL at the pasteboard level without
            // mirroring it into the item provider's registered types.
            || pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier])
        logClassification(of: providers, pasteboard: pasteboard, matched: matched)
        return matched
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
            switch classification(of: provider) {
            case .image(let contentType):
                if let attachment = await materializeImage(
                    provider,
                    contentType: contentType
                ) {
                    results.append(attachment)
                }
            case .file(let contentType):
                if let attachment = await materializeFile(
                    provider,
                    contentType: contentType
                ) {
                    results.append(attachment)
                }
            case nil:
                continue
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
        // Last resort for sources that register a file URL at the pasteboard
        // level without a provider representation: copy the URLs directly.
        // This is a content read, which is fine here — materialization only
        // runs for a user-invoked paste.
        if results.isEmpty,
           pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            for url in pasteboard.urls ?? [] where url.isFileURL {
                let hasScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScope { url.stopAccessingSecurityScopedResource() }
                }
                if let copied = copyIntoTemporaryStorage(
                    url,
                    name: url.lastPathComponent
                ) {
                    results.append(MobilePastedAttachment(
                        kind: .file,
                        url: copied,
                        displayName: copied.lastPathComponent
                    ))
                }
            }
        }
        return results
    }

    /// Copy one security-scoped picked file (e.g. from a Files importer) into
    /// the same app-owned wrapper the paste path uses, so both entry points
    /// feed one staging flow and one cleanup.
    func materializePickedFile(at url: URL) async -> MobilePastedAttachment? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask(priority: .utility) {
                let hasScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasScope { url.stopAccessingSecurityScopedResource() }
                }
                return copyIntoTemporaryStorage(url, name: url.lastPathComponent)
            }
            guard let copied = await group.next() ?? nil else { return nil }
            return MobilePastedAttachment(
                kind: .file,
                url: copied,
                displayName: copied.lastPathComponent
            )
        }
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

    func classification(of provider: NSItemProvider) -> ItemClassification? {
        classification(ofRegisteredTypeIdentifiers: provider.registeredTypeIdentifiers)
    }

    /// Pure classification over registered type identifiers, ordered
    /// most-specific-first as NSItemProvider reports them.
    func classification(
        ofRegisteredTypeIdentifiers identifiers: [String]
    ) -> ItemClassification? {
        let types = identifiers.compactMap { UTType($0) }
        if let imageType = types.first(where: { $0.conforms(to: .image) }) {
            return .image(loadAs: imageType)
        }
        if identifiers.contains(UTType.fileURL.identifier) {
            return .file(loadAs: .fileURL)
        }
        // A text or web-URL flavor anywhere on the item means the user copied
        // something meant to paste AS text (rich text, a link with a title),
        // even when a data flavor (web archive, RTFD) rides along.
        let hasTextFlavor = types.contains {
            $0.conforms(to: .text) || $0 == .url
        }
        guard !hasTextFlavor else { return nil }
        if let dataType = types.first(where: {
            $0.conforms(to: .data) && !$0.conforms(to: .url)
        }) {
            return .file(loadAs: dataType)
        }
        return nil
    }

    /// One privacy-acceptable debug line per probe: type identifiers only
    /// (never content), so a Files.app copy that fails to classify on a
    /// dogfood device can be diagnosed from the copied-off debug log.
    private func logClassification(
        of providers: [NSItemProvider],
        pasteboard: UIPasteboard,
        matched: Bool
    ) {
        #if DEBUG
        let items = providers
            .map { provider in
                "[" + provider.registeredTypeIdentifiers.joined(separator: "|") + "]"
            }
            .joined(separator: ",")
        MobileDebugLog.shared.append(
            "paste.probe matched=\(matched ? 1 : 0) hasImages=\(pasteboard.hasImages ? 1 : 0) "
                + "hasStrings=\(pasteboard.hasStrings ? 1 : 0) hasURLs=\(pasteboard.hasURLs ? 1 : 0) "
                + "items=\(items.isEmpty ? "none" : items)"
        )
        #endif
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
                let name = pastedFileName(
                    suggested: suggestedName,
                    loaded: loaded,
                    contentType: contentType,
                    fallbackStem: "pasted-image"
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
        _ provider: NSItemProvider,
        contentType: UTType
    ) async -> MobilePastedAttachment? {
        let suggestedName = provider.suggestedName
        let url: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: contentType.identifier
            ) { loaded, _ in
                let name: String
                if contentType == .fileURL {
                    // A URL-backed load lands with the real file's own name.
                    name = loaded?.lastPathComponent ?? UUID().uuidString
                } else {
                    name = pastedFileName(
                        suggested: suggestedName,
                        loaded: loaded,
                        contentType: contentType,
                        fallbackStem: "pasted-file"
                    )
                }
                continuation.resume(
                    returning: loaded.flatMap {
                        copyIntoTemporaryStorage($0, name: name)
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

    /// A user-presentable file name whose extension matches the loaded
    /// representation: the provider's suggested name when present, else the
    /// loaded file's own name, else the given fallback stem.
    private func pastedFileName(
        suggested: String?,
        loaded: URL?,
        contentType: UTType,
        fallbackStem: String
    ) -> String {
        let ext = loaded?.pathExtension.isEmpty == false
            ? loaded!.pathExtension
            : (contentType.preferredFilenameExtension ?? "bin")
        if let suggested, !suggested.isEmpty {
            let stem = (suggested as NSString).deletingPathExtension
            let suggestedExt = (suggested as NSString).pathExtension
            return suggestedExt.isEmpty ? "\(stem).\(ext)" : suggested
        }
        if let loadedName = loaded?.deletingPathExtension().lastPathComponent,
           !loadedName.isEmpty {
            return "\(loadedName).\(ext)"
        }
        return "\(fallbackStem).\(ext)"
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
