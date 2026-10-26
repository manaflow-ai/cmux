public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups

/// The agent panes' last pages, saved at quit and drawn under each pane at launch until its live page
/// paints, so a relaunch never shows an empty agent pane (sweep 4a). One image per tab, named with its
/// point scale; a save replaces the whole set. Each image is handed out once per launch. A JPEG or a PNG,
/// as `CGImage.pageImageData` encodes it.
///
/// The launch reads and decodes every saved page off the main thread from its start
/// (``prefetch(on:keep:mark:)``, called in the app's `main` before `NSApplication.run`, so before any
/// window exists). A pane asks with ``take(_:size:appearance:)`` at its first frame and never waits: it gets
/// its page when the read has ended (``LaunchRead``: no main-actor hop), else nothing (it shows its loading
/// state, as with no saved page).
///
/// ```swift
/// let images = AgentPaneLaunchImages(state: stateDirectory)
/// images.prefetch(on: work, mark: { DebugTimings.markLaunch($0) })
/// ```
public final class AgentPaneLaunchImages {
    /// The folder of the saved pages in the tag's state directory.
    public static let directoryName = "agent-pane-images"
    /// A larger file is not read.
    nonisolated static let maximumBytes = 8 << 20
    /// The most saved pages one launch reads (one per pane on screen at the last quit).
    nonisolated static let maximumFiles = 64

    let directory: URL?
    /// Reads the saved pages.
    private let reader: LaunchFileReader
    /// Drops the read's pages after ``prefetch(on:keep:mark:)``'s `keep`.
    private let discard: DemandTimer
    /// Released pages' last frames (AgentPageHibernation), in memory as encoded images: a page built
    /// again draws its old frame until it paints, as at launch.
    private var held: [String: (data: Data, size: NSSize, appearance: NSAppearance.Name?)] = [:]
    /// The launch read of the saved pages, decoded, by tab key (``prefetch(on:keep:mark:)``); nil before it
    /// starts and once its pages are dropped.
    private var read: LaunchRead<[String: Page]>?
    /// The saved pages handed out (each once per launch).
    private var taken: Set<String> = []
    /// Records a launch mark.
    private var mark: @Sendable (String) -> Void = { _ in }
    /// Whether the read's results were dropped (``prefetch(on:keep:mark:)`` then starts no new read).
    private var readDropped = false

    /// A saved page, decoded, with its point size.
    private nonisolated struct Page: Sendable {
        let image: CGImage
        let size: NSSize
    }

    /// - Parameters:
    ///   - directory: The saved pages' folder; nil keeps none.
    ///   - reader: Reads them; default from disk (tests record where it runs, or hold it).
    ///   - clock: Times ``prefetch(on:keep:mark:)``'s `keep`; tests pass their own.
    public init(directory: URL?, reader: LaunchFileReader = LaunchFileReader(), clock: any Clock<Duration> = ContinuousClock()) {
        self.directory = directory
        self.reader = reader
        discard = DemandTimer(owner: "agent-pane.launch-images.keep", clock: clock)
    }

    /// The saved pages in `state`, the tag's state directory (beside its launch snapshot).
    public convenience init(state: URL?) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory))
    }

    /// Starts reading and decoding every saved page on `work`'s files lane at once; a later call does nothing.
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - keep: How long the pages no pane took stay in memory (decoded pages are large), from now.
    ///   - mark: Records the launch marks `agent_pane.launch_images_read` (on the lane, when the pages are
    ///     decoded: a pane asking after that gets its page) and `agent_pane.launch_image_missed` (a pane
    ///     asked before that and showed its loading state).
    /// - Returns: A task that ends with the read (tests await it).
    @discardableResult
    public func prefetch(on work: BackgroundWork, keep: Duration = .seconds(30),
                         mark: @escaping @Sendable (String) -> Void = { _ in }) -> Task<Void, Never>? {
        guard let directory, read == nil, !readDropped else { return nil }
        self.mark = mark
        let reader = reader
        let read = LaunchRead(on: work) {
            let pages = Self.readAll(in: directory, reader)
            mark("agent_pane.launch_images_read")
            return pages
        }
        self.read = read
        // A deadline: the pages no pane took by then are dropped (decoded pages are large).
        discard.schedule(after: keep) { @MainActor [weak self] in self?.dropRead() }
        // task-owner: ends with the read; only tests await it.
        return Task { _ = await read.finished() }
    }

    /// Drops the read's results that no pane took.
    private func dropRead() {
        read = nil
        readDropped = true
    }

    /// `key`'s last page for its pane's first frame, at once, never waiting. A released page's frame
    /// comes first, once, when the pane still has its size (zero: not laid out yet) and appearance:
    /// after a resize or a light/dark switch the pane shows its loading state instead. Then the page the
    /// last quit saved, once, if the launch read has ended; before then nil (the pane shows its loading
    /// state, as with no saved page).
    public func take(_ key: String, size: NSSize = .zero, appearance: NSAppearance.Name? = nil) -> NSImage? {
        if let frame = held.removeValue(forKey: key), frame.appearance == appearance, size == .zero || size == frame.size,
           let rep = NSBitmapImageRep(data: frame.data) {
            let image = NSImage(size: frame.size)
            rep.size = frame.size
            image.addRepresentation(rep)
            return image
        }
        guard let read else { return nil }
        guard let pages = read.value else {
            mark("agent_pane.launch_image_missed")
            return nil
        }
        guard let page = pages[key], taken.insert(key).inserted else { return nil }
        return NSImage(cgImage: page.image, size: page.size)
    }

    /// Holds `image` as tab `key`'s frame until ``take(_:size:appearance:)`` or ``drop(_:)``.
    public func hold(_ key: String, _ frame: CGImage, size: NSSize, appearance: NSAppearance.Name?) async {
        guard size.width > 0 else { return }
        let data = await Task.detached(priority: .utility) { frame.pageImageData() }.value
        held[key] = data.map { ($0, size, appearance) }
    }

    /// The tab closed or showed its live page: its held frame goes.
    public func drop(_ key: String) {
        held[key] = nil
    }

    /// Replaces the saved pages with `images` (by tab key).
    public func save(_ images: [String: NSImage]) async {
        guard let directory else { return }
        // NSImage stays on the main actor; the encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        for (key, image) in images where Self.isFileSafe(key) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else { continue }
            let scale = max(1, min(3, Int((CGFloat(cgImage.width) / image.size.width).rounded())))
            frames[Self.fileName(key, scale: scale, ext: cgImage.pageImageExtension)] = cgImage
        }
        await Task.detached(priority: .utility) { Self.write(frames.compactMapValues { $0.pageImageData() }, to: directory) }.value
    }

    /// Every saved page in `directory`, decoded, with its point size, by tab key: for each key the first
    /// kind a save may have written (one at a time: a save replaces the set).
    private nonisolated static func readAll(in directory: URL, _ reader: LaunchFileReader) -> [String: Page] {
        let names = Set(((try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().prefix(maximumFiles))
        var pages: [String: Page] = [:]
        for (scale, ext) in [2, 1, 3].flatMap({ scale in ["png", "jpg"].map { (scale, $0) } }) {
            let suffix = "@\(scale)x.\(ext)"
            for name in names where name.hasSuffix(suffix) {
                let key = String(name.dropLast(suffix.count))
                guard pages[key] == nil, isFileSafe(key),
                      let page = reader.image(at: directory.appending(path: name), maximumBytes: maximumBytes) else { continue }
                pages[key] = Page(image: page, size: NSSize(width: CGFloat(page.width) / CGFloat(scale), height: CGFloat(page.height) / CGFloat(scale)))
            }
        }
        return pages
    }

    private nonisolated static func write(_ files: [String: Data], to directory: URL) {
        let manager = FileManager.checked
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where files[old] == nil {
            try? manager.removeItem(at: directory.appending(path: old))
        }
        for (name, data) in files {
            let url = directory.appending(path: name)
            guard (try? data.blockingWrite(to: url, options: [.atomic])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private nonisolated static func fileName(_ key: String, scale: Int, ext: String) -> String { "\(key)@\(scale)x.\(ext)" }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    private nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
