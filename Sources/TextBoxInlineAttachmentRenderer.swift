import AppKit
import CmuxFoundation
import CoreGraphics
import Foundation

@MainActor
final class TextBoxInlineAttachmentRenderer {
    private static let maximumConcurrentThumbnailRequests = 2

    private let onThumbnailReady: @MainActor (UUID) -> Void
    private var renderedImages: [
        UUID: [TextBoxInlineAttachmentRenderKey: [Bool: NSImage]]
    ] = [:]
    private var normalizedThumbnails: [
        UUID: [TextBoxInlineAttachmentThumbnailSize: NSImage]
    ] = [:]
    private var queuedThumbnailRequests: [TextBoxInlineAttachmentThumbnailRequest] = []
    private var queuedThumbnailRequestSet: Set<TextBoxInlineAttachmentThumbnailRequest> = []
    private var runningThumbnailTasks: [
        TextBoxInlineAttachmentThumbnailRequest: Task<Void, Never>
    ] = [:]
    private var failedThumbnailSizes: [UUID: TextBoxInlineAttachmentThumbnailSize] = [:]
    private var thumbnailGenerations: [UUID: UInt64] = [:]
    private var activeAttachmentIDs: Set<UUID> = []

    init(onThumbnailReady: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.onThumbnailReady = onThumbnailReady
    }

    deinit {
        for task in runningThumbnailTasks.values {
            task.cancel()
        }
    }

    func image(
        for attachment: TextBoxAttachment,
        font: NSFont,
        foregroundColor: NSColor,
        isFocused: Bool,
        appearance: NSAppearance,
        backingScale: CGFloat
    ) -> NSImage {
        let textFont = GlobalFontMagnification.systemFont(ofSize: 11, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: foregroundColor.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ]
        let textWidth = min(
            TextBoxLayout.inlineAttachmentMaxTextWidth,
            ceil((attachment.displayName as NSString).size(withAttributes: textAttributes).width)
        )
        let height = TextBoxLayout.attachmentChipHeight
        let iconSize = TextBoxLayout.attachmentImageSize
        let width: CGFloat = 6 * 2
            + iconSize
            + 4
            + textWidth
            + TextBoxLayout.inlineAttachmentTrailingControlWidth
        let scale = max(1, backingScale)
        let thumbnailSize = TextBoxInlineAttachmentThumbnailSize(
            width: Int(ceil(iconSize * scale)),
            height: Int(ceil(iconSize * scale))
        )
        let normalizedThumbnail = normalizedThumbnails[attachment.id]?[thumbnailSize]

        if normalizedThumbnail == nil,
           let thumbnailSource = attachment.inlineThumbnailSource {
            requestThumbnail(
                attachmentID: attachment.id,
                source: thumbnailSource,
                pixelSize: thumbnailSize,
                pointSize: NSSize(width: iconSize, height: iconSize)
            )
        }

        var foregroundComponents: [CGFloat] = []
        var accentComponents: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            foregroundComponents = colorComponents(foregroundColor)
            accentComponents = colorComponents(.controlAccentColor)
        }
        let key = TextBoxInlineAttachmentRenderKey(
            attachmentID: attachment.id,
            displayName: attachment.displayName,
            fontName: font.fontDescriptor.postscriptName ?? font.fontName,
            fontSize: font.pointSize,
            fontTraits: font.fontDescriptor.symbolicTraits.rawValue,
            foregroundComponents: foregroundComponents,
            accentComponents: accentComponents,
            appearanceName: appearance.name.rawValue,
            backingScale: scale,
            width: width,
            height: height,
            iconSize: iconSize,
            thumbnailGeneration: thumbnailGenerations[attachment.id, default: 0]
        )
        if let cached = renderedImages[attachment.id]?[key]?[isFocused] {
            return cached
        }

        let image = renderImage(
            attachment: attachment,
            normalizedThumbnail: normalizedThumbnail,
            textAttributes: textAttributes,
            textWidth: textWidth,
            size: NSSize(width: width, height: height),
            iconSize: iconSize,
            isFocused: isFocused,
            foregroundColor: foregroundColor,
            appearance: appearance,
            backingScale: scale
        )
        var focusVariants = renderedImages[attachment.id]?[key] ?? [:]
        focusVariants[isFocused] = image
        renderedImages[attachment.id] = [key: focusVariants]
        return image
    }

    func retainAttachments(withIDs attachmentIDs: Set<UUID>) {
        activeAttachmentIDs = attachmentIDs
        renderedImages = renderedImages.filter { attachmentIDs.contains($0.key) }
        normalizedThumbnails = normalizedThumbnails.filter {
            attachmentIDs.contains($0.key)
        }
        failedThumbnailSizes = failedThumbnailSizes.filter {
            attachmentIDs.contains($0.key)
        }
        thumbnailGenerations = thumbnailGenerations.filter {
            attachmentIDs.contains($0.key)
        }
        cancelThumbnailRequests(excludingAttachmentIDs: attachmentIDs)
    }

    func removeAttachments(withIDs attachmentIDs: Set<UUID>) {
        guard !attachmentIDs.isEmpty else { return }
        activeAttachmentIDs.subtract(attachmentIDs)
        renderedImages = renderedImages.filter { !attachmentIDs.contains($0.key) }
        normalizedThumbnails = normalizedThumbnails.filter {
            !attachmentIDs.contains($0.key)
        }
        failedThumbnailSizes = failedThumbnailSizes.filter {
            !attachmentIDs.contains($0.key)
        }
        thumbnailGenerations = thumbnailGenerations.filter {
            !attachmentIDs.contains($0.key)
        }
        cancelThumbnailRequests(forAttachmentIDs: attachmentIDs)
    }

    private func requestThumbnail(
        attachmentID: UUID,
        source: TextBoxInlineAttachmentThumbnailSource,
        pixelSize: TextBoxInlineAttachmentThumbnailSize,
        pointSize: NSSize
    ) {
        activeAttachmentIDs.insert(attachmentID)
        guard failedThumbnailSizes[attachmentID] != pixelSize else {
            return
        }
        let request = TextBoxInlineAttachmentThumbnailRequest(
            attachmentID: attachmentID,
            source: source,
            pixelSize: pixelSize,
            pointSize: pointSize
        )
        if let runningTask = runningThumbnailTasks[request],
           !runningTask.isCancelled {
            return
        }
        guard queuedThumbnailRequestSet.insert(request).inserted else {
            return
        }
        cancelThumbnailRequests(
            forAttachmentID: attachmentID,
            excludingPixelSize: pixelSize
        )
        queuedThumbnailRequests.append(request)
        startQueuedThumbnailRequests()
    }

    private func startQueuedThumbnailRequests() {
        while runningThumbnailTasks.count < Self.maximumConcurrentThumbnailRequests,
              let requestIndex = queuedThumbnailRequests.lastIndex(where: {
                  runningThumbnailTasks[$0] == nil
              }) {
            let request = queuedThumbnailRequests.remove(at: requestIndex)
            queuedThumbnailRequestSet.remove(request)
            guard activeAttachmentIDs.contains(request.attachmentID) else { continue }

            let task = Task { [weak self] in
                let pixels = await request.source.thumbnail(pixelSize: request.pixelSize)
                let wasCancelled = Task.isCancelled
                guard let self else { return }
                completeThumbnailRequest(
                    request,
                    pixels: wasCancelled ? nil : pixels,
                    wasCancelled: wasCancelled
                )
            }
            runningThumbnailTasks[request] = task
        }
    }

    private func completeThumbnailRequest(
        _ request: TextBoxInlineAttachmentThumbnailRequest,
        pixels: TextBoxInlineAttachmentThumbnailPixels?,
        wasCancelled: Bool
    ) {
        runningThumbnailTasks.removeValue(forKey: request)
        defer { startQueuedThumbnailRequests() }
        guard !wasCancelled,
              activeAttachmentIDs.contains(request.attachmentID) else {
            return
        }
        guard let pixels,
              let thumbnail = image(from: pixels, pointSize: request.pointSize) else {
            failedThumbnailSizes[request.attachmentID] = request.pixelSize
            return
        }

        normalizedThumbnails[request.attachmentID] = [request.pixelSize: thumbnail]
        failedThumbnailSizes.removeValue(forKey: request.attachmentID)
        thumbnailGenerations[request.attachmentID, default: 0] &+= 1
        renderedImages.removeValue(forKey: request.attachmentID)
        onThumbnailReady(request.attachmentID)
    }

    private func cancelThumbnailRequests(excludingAttachmentIDs attachmentIDs: Set<UUID>) {
        cancelThumbnailRequests { !attachmentIDs.contains($0.attachmentID) }
    }

    private func cancelThumbnailRequests(forAttachmentIDs attachmentIDs: Set<UUID>) {
        cancelThumbnailRequests { attachmentIDs.contains($0.attachmentID) }
    }

    private func cancelThumbnailRequests(
        forAttachmentID attachmentID: UUID,
        excludingPixelSize pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) {
        cancelThumbnailRequests {
            $0.attachmentID == attachmentID && $0.pixelSize != pixelSize
        }
    }

    private func cancelThumbnailRequests(
        matching shouldCancel: (TextBoxInlineAttachmentThumbnailRequest) -> Bool
    ) {
        queuedThumbnailRequests.removeAll { request in
            guard shouldCancel(request) else { return false }
            queuedThumbnailRequestSet.remove(request)
            return true
        }
        for (request, task) in runningThumbnailTasks where shouldCancel(request) {
            task.cancel()
        }
        startQueuedThumbnailRequests()
    }

    private func renderImage(
        attachment: TextBoxAttachment,
        normalizedThumbnail: NSImage?,
        textAttributes: [NSAttributedString.Key: Any],
        textWidth: CGFloat,
        size: NSSize,
        iconSize: CGFloat,
        isFocused: Bool,
        foregroundColor: NSColor,
        appearance: NSAppearance,
        backingScale: CGFloat
    ) -> NSImage {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(ceil(size.width * backingScale))),
            pixelsHigh: max(1, Int(ceil(size.height * backingScale))),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        bitmap.size = size
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.imageInterpolation = .high

            let bounds = NSRect(origin: .zero, size: size)
            NSColor.clear.setFill()
            bounds.fill()
            foregroundColor.withAlphaComponent(isFocused ? 0.16 : 0.10).setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: size.height / 2,
                yRadius: size.height / 2
            ).fill()

            let border = isFocused
                ? NSColor.controlAccentColor.withAlphaComponent(0.95)
                : foregroundColor.withAlphaComponent(0.14)
            border.setStroke()
            let borderPath = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: size.height / 2,
                yRadius: size.height / 2
            )
            borderPath.lineWidth = isFocused ? 1.5 : 1
            borderPath.stroke()

            let iconRect = NSRect(
                x: 6,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            if let normalizedThumbnail {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: iconRect, xRadius: 4, yRadius: 4).addClip()
                normalizedThumbnail.draw(in: iconRect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let symbolName = attachment.inlineThumbnailSource == nil ? "doc" : "photo"
                let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                icon?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))?
                    .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.9)
            }

            let textSize = (attachment.displayName as NSString).size(
                withAttributes: textAttributes
            )
            let textRect = NSRect(
                x: iconRect.maxX + 4,
                y: (size.height - textSize.height) / 2,
                width: textWidth,
                height: textSize.height
            )
            (attachment.displayName as NSString).draw(
                in: textRect,
                withAttributes: textAttributes
            )

            let closeAttributes: [NSAttributedString.Key: Any] = [
                .font: GlobalFontMagnification.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: foregroundColor.withAlphaComponent(0.48)
            ]
            let closeString = "×" as NSString
            let closeSize = closeString.size(withAttributes: closeAttributes)
            closeString.draw(
                at: NSPoint(
                    x: bounds.maxX - 6 - closeSize.width + 1,
                    y: (size.height - closeSize.height) / 2
                ),
                withAttributes: closeAttributes
            )
        }

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }

    private func image(
        from pixels: TextBoxInlineAttachmentThumbnailPixels,
        pointSize: NSSize
    ) -> NSImage? {
        guard pixels.rgba8.count == pixels.bytesPerRow * pixels.size.height,
              let provider = CGDataProvider(data: pixels.rgba8 as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                width: pixels.size.width,
                height: pixels.size.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: pointSize)
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }

    private func colorComponents(_ color: NSColor) -> [CGFloat] {
        guard let resolved = color.usingColorSpace(.sRGB) else {
            return [0, 0, 0, color.alphaComponent]
        }
        return [
            resolved.redComponent,
            resolved.greenComponent,
            resolved.blueComponent,
            resolved.alphaComponent
        ]
    }
}
