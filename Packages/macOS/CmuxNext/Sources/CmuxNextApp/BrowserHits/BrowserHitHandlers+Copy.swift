import AppKit
import CmuxNextActions
import CmuxNextBrowser

extension BrowserHitHandlers {
    // MARK: Copy

    static func bindCopy(_ registry: ActionRegistry, _ context: AppActionContext,
                         _ pasteboard: @escaping @MainActor () -> any BrowserPasteboard) {
        // Red: the copy rows are not bound yet.
    }

    // MARK: Save

    /// Save Link As… and Save Image As…: a save panel, then the page's own
    /// download into the chosen file (WebKit). A Chromium page hands the
    /// row back to Chromium's own Save … As while its menu is open.
    static func bindSave(_ registry: ActionRegistry, _ context: AppActionContext) {
        let rows: [(ActionID, BrowserEngineMenuCommand)] = [("browser.link.saveAs", .saveLinkAs), ("browser.image.saveAs", .saveImageAs)]
        for (id, command) in rows {
            registry.bind(id, run: { invocation in
                let url = try Self.url(invocation)
                guard let page = Self.page(invocation, context) else { throw ActionFailure(message: BrowserHitStrings.noPage) }
                guard let saving = page as? any BrowserURLSaving else {
                    // TODO(R123, browser lead): Chromium saves through the shim's
                    // download API with this save panel once it exists.
                    if context.services.cache.pageRequests.runEngineCommand(command, for: page) { return }
                    throw ActionFailure(message: BrowserHitStrings.chromiumSave)
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
    static let limit = 64 << 20

    static func load(_ url: URL, session: URLSession = .shared) async throws -> Data {
        guard ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
