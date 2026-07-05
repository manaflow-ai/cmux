internal import AppKit
internal import UniformTypeIdentifiers

extension TerminalPasteboardService {
    /// Extracts the decodable image payloads from a pasteboard, in item
    /// order: direct image data first, then RTFD attachments, then a
    /// re-rendered fallback, normalizing TIFF to PNG throughout.
    func imageRepresentations(
        in pasteboard: NSPasteboard
    ) -> [(data: Data, fileExtension: String)] {
        let itemRepresentations = (pasteboard.pasteboardItems ?? [])
            .flatMap { item in
                let representations = imageRepresentations(in: item)
                if !representations.isEmpty {
                    return representations
                }
                return pasteboardFallbackImageRepresentations(for: item)
            }
        if !itemRepresentations.isEmpty {
            return itemRepresentations
        }
        if let directImage = directImageRepresentation(in: pasteboard) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: pasteboard)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: pasteboard) {
            return [fallbackImage]
        }
        return []
    }

    private func rtfdAttachmentImageRepresentations(
        from attributed: NSAttributedString
    ) -> [(data: Data, fileExtension: String)] {
        var results: [(data: Data, fileExtension: String)] = []
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }

            if let fileWrapper = attachment.fileWrapper,
               let data = fileWrapper.regularFileContents,
               let imageRepresentation = imageAttachmentRepresentation(
                data: data,
                preferredFilename: fileWrapper.preferredFilename
               ) {
                results.append(imageRepresentation)
            }
        }

        return results
    }

    private func rtfdAttachmentImageRepresentations(
        in pasteboard: NSPasteboard
    ) -> [(data: Data, fileExtension: String)] {
        guard let attributed = attributedString(
            from: pasteboard,
            type: .rtfd,
            documentType: .rtfd
        ) else { return [] }
        return rtfdAttachmentImageRepresentations(from: attributed)
    }

    private func rtfdAttachmentImageRepresentations(
        in item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        guard let attributed = attributedString(
            from: item,
            type: .rtfd,
            documentType: .rtfd
        ) else { return [] }
        return rtfdAttachmentImageRepresentations(from: attributed)
    }

    private func imageAttachmentRepresentation(
        data: Data,
        preferredFilename: String?
    ) -> (data: Data, fileExtension: String)? {
        let pathExtension =
            (preferredFilename as NSString?)?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        if let type = !pathExtension.isEmpty ? UTType(filenameExtension: pathExtension) : nil,
           type.conforms(to: .image),
           let fileExtension = type.preferredFilenameExtension ?? nonEmpty(pathExtension) {
            if isTIFFType(type) {
                return normalizedPNGRepresentation(from: data)
            }
            return (data, fileExtension)
        }

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension else { return nil }
        if isTIFFType(type) {
            return normalizedPNGRepresentation(from: data)
        }
        return (data, fileExtension)
    }

    private func imageDataRepresentation(
        data: Data,
        type: NSPasteboard.PasteboardType
    ) -> (data: Data, fileExtension: String)? {
        guard let utType = UTType(type.rawValue),
              utType.conforms(to: .image),
              let fileExtension = utType.preferredFilenameExtension,
              !fileExtension.isEmpty else { return nil }
        if isTIFFType(utType) {
            return normalizedPNGRepresentation(from: data)
        }
        return (data, fileExtension)
    }

    private func isTIFFType(_ type: UTType) -> Bool {
        type == .tiff || type.conforms(to: .tiff)
    }

    private func normalizedPNGRepresentation(from data: Data) -> (data: Data, fileExtension: String)? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (pngData, "png")
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func directImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        for type in pasteboard.types ?? [] {
            guard type != .png,
                  let imageData = pasteboard.data(forType: type),
                  let representation = imageDataRepresentation(data: imageData, type: type) else { continue }
            return representation
        }

        return nil
    }

    private func directImageRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = item.data(forType: .png) {
            return (pngData, "png")
        }

        for type in item.types {
            guard type != .png,
                  let imageData = item.data(forType: type),
                  let representation = imageDataRepresentation(data: imageData, type: type) else { continue }
            return representation
        }

        return nil
    }

    private func fallbackImageRepresentation(
        in item: NSPasteboardItem
    ) -> (data: Data, fileExtension: String)? {
        for type in item.types {
            guard let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let data = item.data(forType: type),
                  let normalized = normalizedPNGRepresentation(from: data) else { continue }
            return normalized
        }
        return nil
    }

    private func fallbackImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        guard hasImageData(in: pasteboard),
              let tiffData = NSImage(pasteboard: pasteboard)?.tiffRepresentation else { return nil }
        return normalizedPNGRepresentation(from: tiffData)
    }

    private func imageRepresentations(
        in item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        if let directImage = directImageRepresentation(in: item) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: item)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: item) {
            return [fallbackImage]
        }
        return []
    }

    private func pasteboardFallbackImageRepresentations(
        for item: NSPasteboardItem
    ) -> [(data: Data, fileExtension: String)] {
        guard let copiedItem = copiedPasteboardItem(from: item) else { return [] }

        let pasteboard = NSPasteboard(name: .init("cmux-single-image-item-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        guard pasteboard.writeObjects([copiedItem]) else { return [] }

        if let directImage = directImageRepresentation(in: pasteboard) {
            return [directImage]
        }
        let rtfdAttachments = rtfdAttachmentImageRepresentations(in: pasteboard)
        if !rtfdAttachments.isEmpty {
            return rtfdAttachments
        }
        if let fallbackImage = fallbackImageRepresentation(in: pasteboard) {
            return [fallbackImage]
        }
        return []
    }

    private func copiedPasteboardItem(from item: NSPasteboardItem) -> NSPasteboardItem? {
        let copiedItem = NSPasteboardItem()
        var copiedAnyType = false

        for type in item.types {
            if let data = item.data(forType: type) {
                copiedAnyType = copiedItem.setData(data, forType: type) || copiedAnyType
                continue
            }

            if let string = item.string(forType: type) {
                copiedAnyType = copiedItem.setString(string, forType: type) || copiedAnyType
            }
        }

        return copiedAnyType ? copiedItem : nil
    }
}
