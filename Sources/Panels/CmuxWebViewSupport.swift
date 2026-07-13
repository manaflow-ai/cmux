import AppKit
import UniformTypeIdentifiers
import WebKit

extension WKWebView {
    func cmuxOwnsKeyEvent(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window ?? window,
              eventWindow === window,
              let responder = eventWindow.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    nonisolated private static var cmuxSetPageMutedSelector: Selector {
        NSSelectorFromString("_setPageMuted:")
    }

    nonisolated private static var cmuxMediaMutedStateAudio: Int {
        1 << 0
    }

    @discardableResult
    func cmuxSetPageAudioMuted(_ muted: Bool) -> Bool {
        let selector = Self.cmuxSetPageMutedSelector
        guard responds(to: selector),
              let implementation = method(for: selector) else {
            return false
        }

        typealias SetPageMutedFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(implementation, to: SetPageMutedFunction.self)
        function(self, selector, muted ? Self.cmuxMediaMutedStateAudio : 0)
        return true
    }

    var cmuxIsElementFullscreenActiveOrTransitioning: Bool {
        switch fullscreenState {
        case .notInFullscreen:
            return false
        case .enteringFullscreen, .inFullscreen, .exitingFullscreen:
            return true
        @unknown default:
            return true
        }
    }

    func cmuxIsManagedByExternalFullscreenWindow(relativeTo expectedWindow: NSWindow?) -> Bool {
        guard cmuxIsElementFullscreenActiveOrTransitioning else { return false }
        guard let expectedWindow else { return true }
        return window !== expectedWindow
    }
}

struct BrowserImageCopyPasteboardPayload {
    let imageData: Data
    let mimeType: String?
    let sourceURL: URL?
}

enum BrowserFocusModeKeyDecision: Equatable {
    case inactive
    case forwardToWebView
    case consume
}

enum BrowserImageCopyPasteboardBuilder {
    private static let pngPasteboardType = NSPasteboard.PasteboardType(UTType.png.identifier)
    private static let tiffPasteboardType = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    private static let urlPasteboardType = NSPasteboard.PasteboardType(UTType.url.identifier)

    static func makePasteboardItems(from payload: BrowserImageCopyPasteboardPayload) -> [NSPasteboardItem] {
        guard let imageItem = imagePasteboardItem(from: payload) else { return [] }

        var items = [imageItem]
        if let sourceURL = payload.sourceURL {
            // Keep the URL as a secondary item so image-aware paste targets can
            // prefer the binary image payload without losing the textual fallback.
            items.append(urlPasteboardItem(for: sourceURL))
        }
        return items
    }

    private static func imagePasteboardItem(from payload: BrowserImageCopyPasteboardPayload) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        var wroteImageType = false

        if let image = NSImage(data: payload.imageData) {
            if let tiffData = image.tiffRepresentation, !tiffData.isEmpty {
                item.setData(tiffData, forType: tiffPasteboardType)
                wroteImageType = true
            }
            if let pngData = pngData(for: image), !pngData.isEmpty {
                item.setData(pngData, forType: pngPasteboardType)
                wroteImageType = true
            }
        }

        if let sourceType = sourceImageType(mimeType: payload.mimeType, sourceURL: payload.sourceURL) {
            item.setData(payload.imageData, forType: NSPasteboard.PasteboardType(sourceType.identifier))
            wroteImageType = true
        }

        return wroteImageType ? item : nil
    }

    private static func urlPasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .string)
        item.setString(url.absoluteString, forType: urlPasteboardType)
        return item
    }

    private static func sourceImageType(mimeType: String?, sourceURL: URL?) -> UTType? {
        if let mimeType,
           let type = UTType(mimeType: mimeType),
           type.conforms(to: .image) {
            return type
        }

        if let pathExtension = sourceURL?.pathExtension,
           !pathExtension.isEmpty,
           let type = UTType(filenameExtension: pathExtension),
           type.conforms(to: .image) {
            return type
        }

        return nil
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
