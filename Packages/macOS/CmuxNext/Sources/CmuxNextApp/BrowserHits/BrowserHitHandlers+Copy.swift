import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompatAppKit
import CmuxNextWakeups

extension BrowserHitHandlers {
    // MARK: Copy

    static func bindCopy(_ registry: ActionRegistry, _ context: AppActionContext,
                         _ pasteboard: @escaping @MainActor @Sendable () -> any BrowserPasteboard) {
        registry.bind("browser.link.copy", run: { pasteboard().writePageURL(try Self.url($0)) })
        registry.bind("browser.image.copyAddress", run: { pasteboard().writePageURL(try Self.url($0)) })
        registry.bind("browser.link.copyText", run: { pasteboard().writeText(try Self.text($0)) })
        registry.bind("browser.selection.copy", run: { pasteboard().writeText(try Self.text($0)) })
        registry.bind("browser.image.copy", run: { invocation in
            let url = try Self.url(invocation)
            let registry = context.services.registry
            let work = context.services.work
            // The load and the bitmap decode run off main; the pasteboard write is the run's main-thread end
            // (userBlocking for a person's copy, automation for a script's).
            registry.trackWork(owner: "BrowserHitHandlers.copyImage", on: context.services.mainWork) {
                let data = try await BrowserImageData.load(url)
                return (data: data, bitmap: await BrowserImageData.bitmap(data, on: work))
            } then: { result in
                guard case .success(let decoded) = result, let image = BrowserImageData.image(decoded) else {
                    registry.refuse(BrowserHitStrings.imageCopyFailed)
                    return ActionWorkFailure(BrowserHitStrings.imageCopyFailed)
                }
                pasteboard().writeImage(image, source: url)
                return nil
            }
        })
    }

    // MARK: Save

    /// Save Link As… and Save Image As…: a save panel, then the page's own
    /// download into the chosen file, on both engines (WebKit's
    /// `WKDownload`, Chromium's shim downloads), from the menu, the palette
    /// or `action.run` alike.
    static func bindSave(_ registry: ActionRegistry, _ context: AppActionContext) {
        for id: ActionID in ["browser.link.saveAs", "browser.image.saveAs"] {
            registry.bind(id, run: { invocation in
                let url = try Self.url(invocation)
                guard let page = Self.page(invocation, context), let saving = page as? any BrowserURLSaving else {
                    throw ActionFailure(message: BrowserHitStrings.noPage)
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = DownloadDestination.sanitizedFilename(url.lastPathComponent)
                panel.directoryURL = DownloadDestination.defaultDirectory
                let completion: (NSApplication.ModalResponse) -> Void = { [weak saving] response in
                    guard response == .OK, let destination = panel.url else { return }
                    saving?.save(url, to: destination)
                }
                if let window = page.contentView.window {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else {
                    panel.begin(completionHandler: completion)
                }
            })
        }
    }
}

/// The bytes behind an image address for Copy Image. A `data:` address
/// decodes in place; `http(s)` loads without the page's cookies (neither
/// engine gives the host its cached image yet), at most 64 MB.
enum BrowserImageData {
    nonisolated static let limit = 64 << 20

    /// An image address's bytes and, when ImageIO reads a bitmap in them, that bitmap decoded.
    typealias Decoded = (data: Data, bitmap: CGImage?)

    /// The bitmap of `data`, decoded on `work`'s `.cpu` lane, so the pasteboard's TIFF decodes nothing on the main
    /// thread (Chrome decodes images off its UI thread: services/data_decoder/public/cpp/decode_image.h). Nil when
    /// ImageIO reads no bitmap (an SVG).
    nonisolated static func bitmap(_ data: Data, on work: BackgroundWork) async -> CGImage? {
        try? await work.run(.userBlocking, mayBlock: .cpu, { blockingImageDecode(data) })
    }

    /// The image of `decoded` for the pasteboard: the main actor only wraps a decoded bitmap's pixels; what ImageIO
    /// does not read (an SVG) is parsed by `NSImage`, gated by its size. Nil when it is no image.
    static func image(_ decoded: Decoded) -> NSImage? {
        if let bitmap = decoded.bitmap {
            return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        }
        return blockingNSImage(decoded.data)
    }

    nonisolated static func load(_ url: URL, session: URLSession = .shared) async throws -> Data {
        guard ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
