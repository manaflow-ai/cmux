import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import UniformTypeIdentifiers
import CmuxNextCompat

/// A download row's menu in the toolbar's Downloads popup
/// (`BrowserDownloadsPopup`, Edge's downloads flyout, cx-6qwm.1): open the
/// file, show it in Finder, pause, resume or cancel it, retry it, or copy
/// its link. cmux opens a file only on a click there, never by itself. Every
/// row has an icon; the row view themes the menu (`themedMenu()`).
enum BrowserDownloadsMenu {
    /// The right-click menu of `download`'s row; nil when it offers nothing
    /// (a failed blob: download). Each row runs its `browser.download.*`
    /// action on that download, so the palette runs the same handler.
    static func actions(_ download: BrowserDownload, list: BrowserDownloadList) -> NSMenu? {
        let submenu = NSMenu(title: download.filename)
        submenu.autoenablesItems = false
        for (id, title, symbol) in rows(download) {
            let target = ActionMenuClosure { [weak list, weak download] in if let download { list?.run(id, download) } }
            let item = NSMenuItem(title: title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
            (item.target, item.representedObject, item.image) = (target, target, NSImage.menuSymbol(symbol))
            submenu.addItem(item)
        }
        return submenu.items.isEmpty ? nil : submenu
    }

    /// The rows `download` offers now: action, title, symbol.
    static func rows(_ download: BrowserDownload) -> [(ActionID, String, String)] {
        var rows: [(ActionID, String, String)] = []
        if download.status == .finished, download.destination != nil {
            rows.append(("browser.download.open", BrowserHitStrings.downloadOpen, "arrow.up.forward.app"))
            rows.append(("browser.download.reveal", BrowserHitStrings.downloadShowInFinder, "folder"))
        }
        if download.canPause {
            rows.append(download.isPaused ? ("browser.download.togglePause", BrowserHitStrings.downloadResume, "play.circle")
                : ("browser.download.togglePause", BrowserHitStrings.downloadPause, "pause.circle"))
        }
        if download.canRetry { rows.append(("browser.download.retry", BrowserHitStrings.downloadRetry, "arrow.clockwise")) }
        if download.status == .inProgress { rows.append(("browser.download.cancel", BrowserHitStrings.downloadCancel, "xmark.circle")) }
        if link(download) != nil { rows.append(("browser.download.copyLink", BrowserHitStrings.downloadCopyLink, "link")) }
        return rows
    }

    private static func link(_ download: BrowserDownload) -> URL? {
        download.sourceURL.flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
    }

    /// Binds the rows' actions on `list`: the `download` argument is a download's id or file
    /// name (`browserDownloads` lists them, newest first); a row the download does not offer now
    /// refuses with its status.
    static func bind(into registry: ActionRegistry, list: BrowserDownloadList) {
        // A row runs wherever the keyboard is (the popup opens by itself, over a terminal): the
        // list stands in for a focused browser, and the click is the choice (Cancel asks nothing).
        list.run = { [weak registry] id, download in
            guard let registry else { return }
            _ = registry.perform(id, invocation: ActionInvocation(arguments: ["download": .string(download.id.uuidString)], origin: .user,
                                                                  keyContext: registry.context.union(.browserFocused)).confirmed())
        }
        let previous = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak list] source in
            guard source == ActionSuggestions.browserDownloads else { return previous?(source) ?? [] }
            return (list?.items ?? []).reversed().map { ActionEnumCase(value: $0.id.uuidString, title: $0.filename) }
        }
        let body: [ActionID: (BrowserDownload) -> Void] = [
            "browser.download.open": { $0.destination.map { NSWorkspace.shared.openInBackground($0) } },
            "browser.download.reveal": { $0.destination.map { NSWorkspace.shared.revealInBackground([$0]) } },
            "browser.download.togglePause": { $0.setPaused(!$0.isPaused) },
            "browser.download.retry": { [weak list] in _ = list?.retry($0) },
            "browser.download.cancel": { $0.cancel() },
            "browser.download.copyLink": { download in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link(download)?.absoluteString ?? "", forType: .string)
            },
        ]
        for (id, run) in body {
            registry.bindEffect(id, requires: nil, effect: { [weak list] invocation in
                let text = invocation["download"]?.stringValue ?? ""
                guard let download = list?.items.last(where: { $0.id.uuidString == text || $0.filename == text }) else {
                    throw ActionFailure.notFound(BrowserHitStrings.downloadsEmpty)
                }
                guard rows(download).contains(where: { $0.0 == id }) else { throw ActionFailure(message: status(download)) }
                run(download)
                return .done
            })
        }
    }

    /// The file a finished row drags out and opens: its destination while
    /// it is still a regular file there; nil before then or once it is gone.
    static func draggableFile(_ download: BrowserDownload) -> URL? {
        guard download.status == .finished, let file = download.destination?.standardizedFileURL, file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return file
    }

    /// The row's icon: the system icon of its file type.
    static func icon(for download: BrowserDownload, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (download.filename as NSString).pathExtension) ?? .data)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// The row's second line: progress and size while running, else how
    /// it ended.
    static func status(_ download: BrowserDownload) -> String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        switch download.status {
        case .inProgress:
            if download.isPaused { return BrowserHitStrings.downloadPaused }
            let received = size(download.receivedBytes)
            let done = download.totalBytes.map { "\(received) / \(size($0))" } ?? received
            guard let fraction = download.fraction else { return done }
            return "\(fraction.formatted(.percent.precision(.fractionLength(0)))) · \(done)"
        case .finished: return size(download.totalBytes ?? download.receivedBytes)
        case .failed: return BrowserHitStrings.downloadFailedShort
        case .cancelled: return BrowserHitStrings.downloadCancelled
        case .blocked: return BrowserHitStrings.downloadBlockedShort
        }
    }

}
