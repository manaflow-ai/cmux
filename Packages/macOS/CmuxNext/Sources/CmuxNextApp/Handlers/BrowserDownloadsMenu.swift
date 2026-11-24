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
///
/// Each row runs its palette action (`browser.download.*`, `download` = the download's id) through
/// the registry, so the menu and the palette run one handler (``run(_:on:in:)``); ``offers(_:_:)``
/// says which rows a download has, for both.
enum BrowserDownloadsMenu {
    /// The right-click menu of `download`'s row; nil when it offers nothing
    /// (a failed blob: download).
    static func actions(_ download: BrowserDownload, list: BrowserDownloadList, registry: ActionRegistry?) -> NSMenu? {
        let submenu = NSMenu(title: download.filename)
        submenu.autoenablesItems = false
        let pause = download.isPaused ? (BrowserHitStrings.downloadResume, "play.circle") : (BrowserHitStrings.downloadPause, "pause.circle")
        let rows: [(ActionID, String, String)] = [
            ("browser.download.open", BrowserHitStrings.downloadOpen, "arrow.up.forward.app"),
            ("browser.download.reveal", BrowserHitStrings.downloadShowInFinder, "folder"),
            ("browser.download.togglePause", pause.0, pause.1),
            ("browser.download.retry", BrowserHitStrings.downloadRetry, "arrow.clockwise"),
            ("browser.download.cancel", BrowserHitStrings.downloadCancel, "xmark.circle"),
            ("browser.download.copyLink", BrowserHitStrings.downloadCopyLink, "link"),
        ]
        for (id, title, symbol) in rows where offers(id, download) {
            submenu.addItem(closure(title, symbol) { [weak registry] in run(id, on: download, list: list, in: registry) })
        }
        return submenu.items.isEmpty ? nil : submenu
    }

    /// Whether `download` has the row of `id` now: Open and Show in Finder for a finished file, Pause or
    /// Resume while the engine can, Retry where it can, Cancel while it runs, Copy Download Link for a web link.
    static func offers(_ id: ActionID, _ download: BrowserDownload) -> Bool {
        switch id.rawValue {
        case "browser.download.open", "browser.download.reveal": file(of: download) != nil
        case "browser.download.togglePause": download.canPause
        case "browser.download.retry": download.canRetry
        case "browser.download.cancel": download.status == .inProgress
        case "browser.download.copyLink": webLink(of: download) != nil
        default: false
        }
    }

    /// A row's palette action on `download`: the menu's choice, confirmed (Cancel asks nothing there), on the
    /// browser the popup stands in for; refused (or with no registry), the row's own effect (``perform``), as before.
    static func run(_ id: ActionID, on download: BrowserDownload, list: BrowserDownloadList, in registry: ActionRegistry?) {
        var invocation = ActionInvocation(arguments: ["download": .string(download.id.uuidString)], origin: .user).confirmed()
        invocation.keyContext = registry?.context.union(.browserFocused)
        if registry?.perform(id, invocation: invocation) != true { _ = perform(id, on: download, list: list) }
    }

    /// What the row of `id` does to `download` (the action's handler); false when the download has no such row now.
    static func perform(_ id: ActionID, on download: BrowserDownload, list: BrowserDownloadList) -> Bool {
        guard offers(id, download) else { return false }
        switch id.rawValue {
        case "browser.download.open": if let file = file(of: download) { NSWorkspace.shared.openInBackground(file) }
        case "browser.download.reveal": if let file = file(of: download) { NSWorkspace.shared.revealInBackground([file]) }
        case "browser.download.togglePause": download.setPaused(!download.isPaused)
        case "browser.download.retry": _ = list.retry(download)
        case "browser.download.cancel": download.cancel()
        case "browser.download.copyLink":
            guard let source = webLink(of: download) else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source.absoluteString, forType: .string)
        default: return false
        }
        return true
    }

    private static func file(of download: BrowserDownload) -> URL? {
        download.status == .finished ? download.destination : nil
    }

    private static func webLink(of download: BrowserDownload) -> URL? {
        guard let source = download.sourceURL, source.scheme == "http" || source.scheme == "https" else { return nil }
        return source
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

    private static func closure(_ title: String, _ symbol: String, _ body: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = ActionMenuClosure(body)
        let item = NSMenuItem(title: title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
        (item.target, item.representedObject, item.image) = (target, target, NSImage.menuSymbol(symbol))
        return item
    }
}
