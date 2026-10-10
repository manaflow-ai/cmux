import AppKit
import CmuxNextActions
import CmuxNextBrowser
import UniformTypeIdentifiers

/// The toolbar's Downloads menu (`browser.downloads.show`, Edge's downloads
/// flyout, cx-6qwm.1): the newest downloads first, each with its progress
/// or end and a submenu to open it, show it in Finder, pause, resume or
/// cancel it, or copy its link; then Open Downloads Folder and Clear.
/// cmux opens a file only on a click here, never by itself.
enum BrowserDownloadsMenu {
    /// Rows listed; the list keeps more (`BrowserDownloadList.limit`).
    static let shown = 12

    static func menu(_ list: BrowserDownloadList, target: ActionTargetRef, registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        let items = list.items.suffix(shown).reversed()
        if items.isEmpty {
            let empty = NSMenuItem(title: BrowserHitStrings.downloadsEmpty, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for download in items { menu.addItem(row(download)) }
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

    private static func row(_ download: BrowserDownload) -> NSMenuItem {
        let item = NSMenuItem(title: download.filename, action: nil, keyEquivalent: "")
        item.subtitle = status(download)
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (download.filename as NSString).pathExtension) ?? .data)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        let submenu = NSMenu(title: download.filename)
        let file = download.status == .finished ? download.destination : nil
        if let file {
            submenu.addItem(closure(BrowserHitStrings.downloadOpen) { NSWorkspace.shared.open(file) })
            submenu.addItem(closure(BrowserHitStrings.downloadShowInFinder) { NSWorkspace.shared.activateFileViewerSelecting([file]) })
        }
        if download.canPause {
            let title = download.isPaused ? BrowserHitStrings.downloadResume : BrowserHitStrings.downloadPause
            submenu.addItem(closure(title) { [weak download] in download.map { $0.setPaused(!$0.isPaused) } })
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
