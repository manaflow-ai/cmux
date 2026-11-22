import CmuxNextMobile
import CryptoKit
public import Foundation

/// Browser tabs' thumbnails and favicons for the phones' tab overview (`tabs`, tab-snapshots-v1): each picture the
/// app has of a page goes to `cmux-mobile-host` as a file in the app's own cache folder, named on a `tab_picture`
/// line. hostd keeps every rule (size cap, JPEG or PNG only, a regular file; `tab_snapshots.rs`) and serves it; this
/// only writes the bytes and skips a picture whose bytes are the ones sent last for that tab and part.
///
/// Files are named by their content, so a write never changes a file hostd may be reading: a newer picture is a new
/// file, and the one before it goes once the newer line is sent. A tab's files go when it closes (``forget(surface:)``).
@MainActor
public final class PhoneTabPictures {
    public enum Part: String, Sendable {
        case thumb
        case favicon
    }

    private nonisolated struct Sent: Sendable {
        var hash: String
        var file: URL
    }

    private weak var iphone: IPhoneHostService?
    private let folder: URL
    /// The picture sent last of each surface's part.
    private var sent: [String: Sent] = [:]
    /// Bumped by every offer and forget of a surface's part: an older write that lands late is dropped.
    private var turns: [String: UInt64] = [:]

    public init(iphone: IPhoneHostService, folder: URL = PhoneTabPictures.defaultFolder) {
        self.iphone = iphone
        self.folder = folder
    }

    /// Where the pictures go: the app's caches, apart from the wallpaper's phone copy.
    public nonisolated static var defaultFolder: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux-next", isDirectory: true)
            .appendingPathComponent("phone-tab-pictures", isDirectory: true)
    }

    /// Whether a phone can get the pictures: iPhone connections are on and one is paired. Until then nothing is
    /// encoded or written.
    public var wanted: Bool {
        guard let iphone else { return false }
        return iphone.allowed && !(iphone.paired?.devices.isEmpty ?? true)
    }

    /// `data` (a JPEG or PNG of `width` x `height` pixels) as `part` of the tab of daemon surface `surface`: written
    /// and handed to hostd unless it is the picture sent last for that tab and part.
    public func offer(surface: UInt64, part: Part, data: Data, width: Int, height: Int) {
        guard wanted, !data.isEmpty else { return }
        let key = "\(surface)-\(part.rawValue)"
        let turn = (turns[key] ?? 0) &+ 1
        turns[key] = turn
        let folder = folder, ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // task-owner: one write per picture; ends on its own (a file write), dropped below when a newer one started.
        Task { [weak self] in
            let written = await Task.detached(priority: .utility) { () -> Sent? in
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let file = folder.appendingPathComponent("\(key)-\(hash.prefix(16)).\(ext)")
                if FileManager.default.fileExists(atPath: file.path) { return Sent(hash: hash, file: file) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                } catch {
                    return nil
                }
                return Sent(hash: hash, file: file)
            }.value
            guard let self, let written else { return }
            guard self.turns[key] == turn else {
                if self.sent[key]?.file != written.file { Self.remove([written.file]) }
                return
            }
            let previous = self.sent[key]
            guard previous?.hash != written.hash else { return }
            self.sent[key] = written
            let line = MobileHostLaunch.tabPictureLine(surface: surface, part: part.rawValue, path: written.file.path,
                                                       width: width, height: height, capturedAtMs: capturedAtMs)
            await self.iphone?.setTabPicture(surface: surface, part: part.rawValue, line: line)
            if let previous, previous.file != written.file { Self.remove([previous.file]) }
        }
    }

    /// The tab of `surface` closed: its files go and no new hostd gets its pictures.
    public func forget(surface: UInt64) {
        var files: [URL] = []
        for part in [Part.thumb, .favicon] {
            let key = "\(surface)-\(part.rawValue)"
            turns[key] = (turns[key] ?? 0) &+ 1
            if let file = sent.removeValue(forKey: key)?.file { files.append(file) }
        }
        if !files.isEmpty { Self.remove(files) }
        let iphone = iphone
        // task-owner: one hop to the supervisor actor; ends on its own.
        Task { await iphone?.forgetTabPictures(surface: surface) }
    }

    private nonisolated static func remove(_ files: [URL]) {
        // task-owner: deletes this class's own files; ends on its own.
        Task.detached(priority: .utility) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}

extension IPhoneHostService {
    /// A browser tab's picture line for the phones (``PhoneTabPictures``): one hop to the supervisor, which keeps the
    /// newest of each tab's part for each new hostd.
    func setTabPicture(surface: UInt64, part: String, line: Data) async {
        await supervisor.setTabPicture(surface: surface, part: part, line: line)
    }

    /// The tab of `surface` closed: no new hostd gets its pictures.
    func forgetTabPictures(surface: UInt64) async {
        await supervisor.forgetTabPictures(surface: surface)
    }
}
