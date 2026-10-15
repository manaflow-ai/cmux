import AppKit
import CmuxNextActions
import CmuxNextBrowser
import UniformTypeIdentifiers
import CmuxNextCompat

/// The toolbar's Downloads menu (`browser.downloads.show`, Edge's downloads
/// flyout, cx-6qwm.1): the newest downloads first, each with its progress
/// or end and a submenu to open it, show it in Finder, pause, resume or
/// cancel it, retry it, or copy its link; then Open Downloads Folder and Clear.
/// cmux opens a file only on a click here, never by itself.
enum BrowserDownloadsMenu {
    /// Rows listed; the list keeps more (`BrowserDownloadList.limit`).
    static let shown = 12

    static func menu(_ list: BrowserDownloadList, target: ActionTargetRef, registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        // A row with nothing to do (a failed blob: download) still reads
        // as a download, not as a disabled command.
        menu.autoenablesItems = false
        let items = list.items.suffix(shown).reversed()
        if items.isEmpty {
            let empty = NSMenuItem(title: BrowserHitStrings.downloadsEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for download in items { menu.addItem(row(download, list: list)) }
        menu.addItem(.separator())
        for item in registry.makeContextMenu(for: .browserPage, target: target, entries: [.action("browser.downloads.showFolder")]).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        if list.items.contains(where: { $0.status != .inProgress }) {
            menu.addItem(closure(BrowserHitStrings.downloadsClear) { [weak list] in list?.clearEnded() })
        }
        return menu
    }

    private static func row(_ download: BrowserDownload, list: BrowserDownloadList) -> NSMenuItem {
        let item = NSMenuItem(title: middleTruncated(download.filename), action: nil, keyEquivalent: "")
        if item.title != download.filename { item.toolTip = download.filename }
        item.showSubtitle(status(download))
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (download.filename as NSString).pathExtension) ?? .data)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        let submenu = NSMenu(title: download.filename)
        let file = download.status == .finished ? download.destination : nil
        if let file {
            submenu.addItem(closure(BrowserHitStrings.downloadOpen) { NSWorkspace.shared.openInBackground(file) })
            submenu.addItem(closure(BrowserHitStrings.downloadShowInFinder) { NSWorkspace.shared.revealInBackground([file]) })
        }
        if download.canPause {
            let title = download.isPaused ? BrowserHitStrings.downloadResume : BrowserHitStrings.downloadPause
            submenu.addItem(closure(title) { [weak download] in download.map { $0.setPaused(!$0.isPaused) } })
        }
        if download.canRetry {
            submenu.addItem(closure(BrowserHitStrings.downloadRetry) { [weak list, weak download] in
                if let list, let download { list.retry(download) }
            })
        }
        if download.status == .inProgress {
            submenu.addItem(closure(BrowserHitStrings.downloadCancel) { [weak download] in download?.cancel() })
        }
        if let source = download.sourceURL, source.scheme == "http" || source.scheme == "https" {
            submenu.addItem(closure(BrowserHitStrings.downloadCopyLink) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            })
        }
        if !submenu.items.isEmpty { item.submenu = submenu }
        return item
    }

    /// A long file name is cut in the middle, so its extension stays readable.
    static func middleTruncated(_ name: String) -> String {
        let limit = 60
        guard name.count > limit else { return name }
        let tail = limit / 3
        return String(name.prefix(limit - tail - 1)) + "…" + String(name.suffix(tail))
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

    private static func closure(_ title: String, _ body: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = ActionMenuClosure(body)
        let item = NSMenuItem(title: title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}
