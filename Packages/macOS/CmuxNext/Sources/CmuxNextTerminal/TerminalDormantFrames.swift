import CmuxNextDesign
import CmuxNextHibernation
import CoreGraphics

/// A hibernated workspace's terminals' last frames, on disk (``TerminalLastFrames/stow(_:)``). An evicted terminal's
/// frame is a full-resolution IOSurface (about 24 MB for a large pane at 2x), volatile but resident until memory
/// pressure comes, so 200 hibernated workspaces kept up to 128 of them, 0.25 to 2 GB of the app's memory. A sleeping
/// terminal keeps a ``DormantRecord`` (kind `terminal`, its tab key) instead, and its frame is a lossless PNG file of a
/// ``HibernationSnapshots`` store (a temporary directory of this launch, under its disk budget, oldest out first),
/// as the browser tabs' and the hidden agent chats' frames are. Showing the terminal again draws that frame until
/// the replay paints, as a frame from the last quit draws at launch (``TerminalLaunchFrame``).
///
/// Leo, 2026-11-22 (goals/infinite-tabs-flat.md): "i also want us to keep pursuing the ability to have infinite
/// f***ing tabs and workspaces and shit without getting starved of cpu/ram".
///
/// The warm set's own evictions (a quick switch away and back) keep their frame in memory: only a workspace that
/// hibernated sleeps. Until its file is encoded, a sleeping frame stays in memory here and shows as before.
@MainActor
final class TerminalDormantFrames {
    /// The frames' disk budget: a terminal frame is 0.3 to 1.5 MB as an unfiltered PNG at 2x, so 256 MB holds
    /// 170 to 850 of them.
    nonisolated static let capacityBytes = 256 << 20

    /// Each sleeping terminal's row; its frame is a file of `files` once encoded.
    private(set) var records: [String: DormantRecord] = [:]
    /// Frames still being encoded, shown from memory if their terminal wakes first.
    private var encoding: [String: TerminalLastFrame] = [:]
    /// Encodes started and not yet stored (tests).
    private var pending: [String: Task<Void, Never>] = [:]
    private lazy var files = HibernationSnapshots(capacityBytes: Self.capacityBytes)

    /// What a waking terminal shows: its frame still in memory, or the picture read back from its file.
    enum Waking {
        case frame(TerminalLastFrame)
        case image(CGImage)
    }

    /// `frame` (`key`'s, just evicted) leaves memory: encoded off the main thread to a file, then dropped.
    func stow(_ frame: TerminalLastFrame, key: String) {
        drop(key)
        encoding[key] = frame
        pending[key] = Task { [weak self] in
            let image = await frame.snapshot(maxPixelSize: .greatestFiniteMagnitude)
            let data = await Task.detached(priority: .utility) { image?.unfilteredPNGData() }.value
            guard let self, self.encoding[key] === frame else { return } // woke or closed meanwhile
            self.pending[key] = nil
            self.encoding[key] = nil
            guard let image, let data else { return } // purged before it was read: no frame, as a purge shows
            self.files.insert(HibernationSnapshots.Picture(data: data, image: image), for: key)
            self.records[key] = DormantRecord(kind: .terminal, key: key, width: frame.pointSize.width,
                                              height: frame.pointSize.height, appearance: frame.appearance, frameBytes: data.count)
        }
    }

    /// `key` shows again: its sleeping frame, if one is kept; the record and file go.
    func wake(_ key: String) -> Waking? {
        if let frame = encoding[key] {
            drop(key)
            return .frame(frame)
        }
        guard records[key] != nil else { return nil }
        // Read before the file goes: the image stays drawable once the store deleted it.
        let image = files.image(for: key)
        drop(key)
        return image.map(Waking.image)
    }

    /// `key` closed, or was evicted afresh: its sleeping frame goes.
    func drop(_ key: String) {
        encoding[key] = nil
        pending.removeValue(forKey: key)?.cancel()
        guard records.removeValue(forKey: key) != nil else { return }
        files.remove(key)
    }

    /// Sleeping frames: still in memory, and on disk (count and bytes).
    var counts: (encoding: Int, stored: Int, bytes: Int) { (encoding.count, records.count, files.totalBytes) }

    /// Returns once every encode started so far is stored and its file written (tests).
    func settled() async {
        for task in pending.values { await task.value }
        await files.settled()
    }
}
