import Foundation
import os

/// A shim download event (DOWNLOAD_STARTED / _PROGRESS / _DONE in
/// cmux_cef_shim.h), decoded.
nonisolated enum CEFDownloadEvent: Equatable, Sendable {
    enum End: Int64, Equatable, Sendable {
        case complete = 1
        case cancelled = 2
        case interrupted = 3
    }

    /// Chromium waits for the path (`cmux_shim_download_continue`).
    /// `browser` is the tab, or 0.
    case started(id: Int32, browser: Int32, url: String, suggestedName: String, totalBytes: Int64?)
    case progress(id: Int32, receivedBytes: Int64, totalBytes: Int64?, bytesPerSecond: Int64?, paused: Bool)
    /// `reason` is Chromium's interrupt reason (0 when none).
    case done(id: Int32, end: End, reason: Int64, path: String)

    init?(kind: Int32, browser: Int32, id: Int32, a: Int64, b: Int64, s1: String, s2: String) {
        switch kind {
        case 34: self = .started(id: id, browser: browser, url: s1, suggestedName: s2, totalBytes: a > 0 ? a : nil)
        case 35:
            self = .progress(id: id, receivedBytes: max(a, 0), totalBytes: b > 0 ? b : nil,
                             bytesPerSecond: Int64(s1), paused: s2 == "paused")
        case 36:
            guard let end = End(rawValue: a) else { return nil }
            self = .done(id: id, end: end, reason: b, path: s1)
        default: return nil
        }
    }
}

/// What `CEFDownloads` needs from the shim (`cmux_shim_download_*`); tests
/// pass a fake.
struct CEFDownloadShim {
    /// Starts a download of a URL with a tab's request context.
    var start: (_ browser: Int32, _ url: String) -> Bool
    /// Answers DOWNLOAD_STARTED with a path; "" cancels.
    var answer: (_ id: Int32, _ path: String) -> Void
    /// 0 cancel, 1 pause, 2 resume.
    var control: (_ id: Int32, _ command: Int32) -> Void
}

/// Chromium downloads as engine-neutral `BrowserDownload`s. Every download
/// Chromium starts (a page's, Option-click, Save Link As, a click mapped to
/// a download) asks here for its path; the answer follows
/// `BrowserDownloadPolicy` (the Downloads folder, or the file the person
/// chose). The tab that started it sends `.download` to the App, which
/// keeps one downloads list for both engines.
final class CEFDownloads {
    private let shim: () -> CEFDownloadShim?
    /// Where downloads go without a chosen file.
    var directory: () -> URL = { DownloadDestination.defaultDirectory }
    var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    /// Removes the file a save panel already agreed to replace.
    var removeReplaced: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    var reservations: BrowserDownloadReservations = .shared
    /// Hands a started download to the App through tab `browser`.
    var deliver: (_ browser: Int32, _ download: BrowserDownload) -> Void = { _, _ in }
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.downloads")

    private var items: [Int32: BrowserDownload] = [:]
    /// Files the person chose (Save Link As…), waiting for their download.
    private var chosen: [(browser: Int32, url: String, destination: URL)] = []

    init(shim: @escaping () -> CEFDownloadShim?) {
        self.shim = shim
    }

    /// Downloads `url` with tab `browser`'s session into the Downloads folder.
    func download(_ url: String, browser: Int32) -> Bool {
        shim()?.start(browser, url) ?? false
    }

    /// Downloads `url` with tab `browser`'s session into `destination`, a
    /// file the person chose.
    func save(_ url: URL, to destination: URL, browser: Int32) -> Bool {
        let address = url.absoluteString
        guard let shim = shim() else { return false }
        chosen.append((browser, address, destination))
        if chosen.count > 16 { chosen.removeFirst(chosen.count - 16) }
        guard shim.start(browser, address) else {
            chosen.removeAll { $0.browser == browser && $0.url == address && $0.destination == destination }
            return false
        }
        return true
    }

    func handle(_ event: CEFDownloadEvent) {
        switch event {
        case let .started(id, browser, url, suggestedName, total):
            started(id: id, browser: browser, url: url, suggestedName: suggestedName, total: total)
        case let .progress(id, received, total, speed, paused):
            items[id]?.update(received: received, total: total, bytesPerSecond: speed, paused: paused)
        case let .done(id, end, reason, path):
            guard let item = items.removeValue(forKey: id) else { return }
            if end == .complete, let destination = item.destination, !path.isEmpty,
               URL(filePath: path).standardizedFileURL != destination.standardizedFileURL {
                logger.error("download \(id) ended at another path than cmux chose")
            }
            switch end {
            case .complete: item.complete(.finished)
            case .cancelled: item.complete(.cancelled)
            case .interrupted: item.complete(.failed("interrupted (\(reason))"))
            }
            logger.notice("download \(id) ended: \(String(describing: end), privacy: .public)")
        }
    }

    private func started(id: Int32, browser: Int32, url: String, suggestedName: String, total: Int64?) {
        guard let shim = shim() else { return }
        let pick = chosen.firstIndex { $0.browser == browser && $0.url == url }.map { chosen.remove(at: $0).destination }
        if let pick { removeReplaced(pick) }
        let destination = BrowserDownloadPolicy.destination(chosen: pick, suggestedFilename: suggestedName,
                                                            directory: directory(), exists: exists)
            ?? directory().appending(path: "download")
        let item = BrowserDownload(sourceURL: URL(string: url), filename: destination.lastPathComponent)
        item.destination = destination
        item.update(received: 0, total: total)
        item.cancelHandler = { shim.control(id, 0) }
        item.pauseHandler = { paused in shim.control(id, paused ? 1 : 2) }
        items[id] = item
        shim.answer(id, destination.path(percentEncoded: false))
        logger.notice("download \(id) started for tab \(browser), chosen=\(pick != nil)")
        deliver(browser, item)
    }
}

extension CEFRuntime {
    /// Downloads: every one asks for its path here (`BrowserDownloadPolicy`).
    /// The runtime is process-wide, and so are its downloads.
    var downloads: CEFDownloads { CEFDownloads.shared }
}

extension CEFDownloads {
    static let shared = forRuntime(.shared)

    /// The runtime's downloads: the loaded shim, delivered through the tab.
    static func forRuntime(_ runtime: CEFRuntime) -> CEFDownloads {
        let downloads = CEFDownloads { [weak runtime] () -> CEFDownloadShim? in
            guard let shim = runtime?.shim else { return nil }
            return CEFDownloadShim(
                start: { browser, url in url.withCString { shim.downloadURL(browser, $0) } == 1 },
                answer: { id, path in _ = path.withCString { shim.downloadContinue(id, $0) } },
                control: { id, command in _ = shim.downloadControl(id, command) }
            )
        }
        let logger = downloads.logger
        downloads.deliver = { [weak runtime] (browser: Int32, item: BrowserDownload) in
            guard let tab = runtime?.tabsByBrowser[browser] else {
                logger.error("download for tab \(browser) without a cmux tab: not in the downloads list")
                return
            }
            tab.emit(.download(item))
        }
        return downloads
    }
}
