import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import UniformTypeIdentifiers
import CmuxNextCompatAppKit

/// A download row's menu in the toolbar's Downloads popup
/// (`BrowserDownloadsPopup`, Edge's downloads flyout, cx-6qwm.1): open the
/// file, show it in Finder, pause, resume or cancel it, retry it, or copy
/// its link. cmux opens a file only on a click there, never by itself. Every
/// row has an icon; the row view themes the menu (`themedMenu()`).
enum BrowserDownloadsMenu {
    /// The right-click menu of `download`'s row; nil when it offers nothing
    /// (a failed blob: download).
    static func actions(_ download: BrowserDownload, list: BrowserDownloadList) -> NSMenu? {
        let submenu = NSMenu(title: download.filename)
        submenu.autoenablesItems = false
        let file = download.status == .finished ? download.destination : nil
        if let file {
            submenu.addItem(closure(BrowserHitStrings.downloadOpen, "arrow.up.forward.app") { NSWorkspace.shared.openInBackground(file) })
            submenu.addItem(closure(BrowserHitStrings.downloadShowInFinder, "folder") { NSWorkspace.shared.revealInBackground([file]) })
        }
        if download.canPause {
            let (title, symbol) = download.isPaused ? (BrowserHitStrings.downloadResume, "play.circle") : (BrowserHitStrings.downloadPause, "pause.circle")
            submenu.addItem(closure(title, symbol) { [weak download] in download.map { $0.setPaused(!$0.isPaused) } })
        }
        if download.canRetry {
            submenu.addItem(closure(BrowserHitStrings.downloadRetry, "arrow.clockwise") { [weak list, weak download] in
                if let list, let download { list.retry(download) }
            })
        }
        if download.status == .inProgress {
            submenu.addItem(closure(BrowserHitStrings.downloadCancel, "xmark.circle") { [weak download] in download?.cancel() })
        }
        if let source = download.sourceURL, source.scheme == "http" || source.scheme == "https" {
            submenu.addItem(closure(BrowserHitStrings.downloadCopyLink, "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            })
        }
        return submenu.items.isEmpty ? nil : submenu
    }

    /// The file a finished row drags out and opens: its destination while
    /// it is still a regular file there; nil before then or once it is gone.
    static func draggableFile(_ download: BrowserDownload) -> URL? {
        guard download.status == .finished, let file = download.destination?.standardizedFileURL, file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return file
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
