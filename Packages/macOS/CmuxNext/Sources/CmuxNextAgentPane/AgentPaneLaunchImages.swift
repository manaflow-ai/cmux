public import AppKit
public import CmuxNextCompat
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
/// Registered (``registerMemoryConsumer(with:)``), the held frames and the launch read are one lossy memory
/// consumer: a dropped frame cannot be made again (its page is gone), and the pane shows its loading state
/// instead, as with no saved page. Below the full limit the read's untaken pages go at once and at most the
/// limit's share of ``maximumFiles`` held frames stay, oldest dropped first; at the critical limit nothing is
/// kept and ``hold(_:_:size:appearance:)`` keeps nothing more.
///
/// ```swift
/// let images = AgentPaneLaunchImages(state: stateDirectory)
/// images.prefetch(on: work, mark: { DebugTimings.markLaunch($0) })
/// images.registerMemoryConsumer(with: memoryCoordinator)
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
    /// again draws its old frame until it paints, as at launch. At most ``heldLimit``, oldest dropped first.
    private var held: [String: HeldFrame] = [:]
    /// The encoded bytes of ``held``, kept on every insert and removal (the memory report).
    private var heldBytes = 0
    /// The order of the next held frame (the oldest has the lowest).
    private var nextHeldOrder = 0
    /// How many held frames it keeps: ``maximumFiles`` scaled by the memory coordinator's limit.
    private var heldLimit = AgentPaneLaunchImages.maximumFiles
    private var memoryRegistration: MemoryConsumerRegistration?
    /// The launch read of the saved pages, decoded, by tab key (``prefetch(on:keep:mark:)``); nil before it
    /// starts and once its pages are dropped.
    private var read: LaunchRead<SavedPages>?
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

    /// The launch read's pages by tab key, with their decoded bytes (counted once, on the read's lane).
    private nonisolated struct SavedPages: Sendable {
        var pages: [String: Page] = [:]
        var bytes = 0
    }

    /// A released page's last frame, encoded, with what the pane must still match to draw it.
    private struct HeldFrame {
        let data: Data
        let size: NSSize
        let appearance: NSAppearance.Name?
        /// Lower is older (``nextHeldOrder``).
        let order: Int
    }

    /// - Parameters:
    ///   - directory: The saved pages' folder; nil keeps none.
    ///   - reader: Reads them; default from disk (tests record where it runs, or hold it).
    ///   - clock: Times ``prefetch(on:keep:mark:)``'s `keep`; tests pass their own.
    public init(directory: URL?, reader: LaunchFileReader = LaunchFileReader(), clock: any Clock<Duration> = ContinuousClock()) {
        self.directory = directory
        self.reader = reader
        // timer-class-allow: armed in the app's main before NSApplication.run (prefetch(on:keep:mark:)), before the
        // composition root makes its deadline scheduler; one 30 s fire per launch that drops unclaimed pages
        discard = DemandTimer(owner: "agent-pane.launch-images.keep", clock: clock)
    }

    /// The saved pages in `state`, the tag's state directory (beside its launch snapshot).
    /// `reader`: reads the saved pages; the app's skips every one in a crash streak's safe launch (`LaunchSafeMode`).
    public convenience init(state: URL?, reader: LaunchFileReader = LaunchFileReader()) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory), reader: reader)
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
        discard.scheduleOnMain(after: keep) { [weak self] in self?.dropRead() }
        // task-owner: ends with the read; only tests await it.
        return Task { _ = await read.finished() }
    }

    /// The launch settled (`LaunchSettle`) and no pane draws a launch page any more: the decoded pages no pane
    /// took go now, not at the keep deadline, and no read starts later. Held frames stay: they are not launch reads.
    public func dropLaunchRead() {
        dropRead()
    }

    /// Drops the read's results that no pane took, and the deadline that would drop them.
    private func dropRead() {
        read = nil
        readDropped = true
        discard.cancel()
    }

    /// `key`'s last page for its pane's first frame, at once, never waiting. A released page's frame
    /// comes first, once, when the pane still has its size (zero: not laid out yet) and appearance:
    /// after a resize or a light/dark switch the pane shows its loading state instead. Then the page the
    /// last quit saved, once, if the launch read has ended; before then nil (the pane shows its loading
    /// state, as with no saved page).
    public func take(_ key: String, size: NSSize = .zero, appearance: NSAppearance.Name? = nil) -> NSImage? {
        // The pane's first frame cannot wait, so the held frame decodes here, as a checked CPU call: a large one on
        // the main thread is a cpu-intensive site, where NSBitmapImageRep(data:) decoded it unseen at its first draw.
        if let frame = removeHeld(key), frame.appearance == appearance, size == .zero || size == frame.size,
           let image = blockingImageDecode(frame.data) {
            return NSImage(cgImage: image, size: frame.size)
        }
        guard let read else { return nil }
        guard let saved = read.value else {
            mark("agent_pane.launch_image_missed")
            return nil
        }
        guard let page = saved.pages[key], taken.insert(key).inserted else { return nil }
        return NSImage(cgImage: page.image, size: page.size)
    }

    /// Holds `image` as tab `key`'s frame until ``take(_:size:appearance:)`` or ``drop(_:)``. Past the memory
    /// limit's share of ``maximumFiles`` the oldest held frame goes; at the critical limit none is kept.
    public func hold(_ key: String, _ frame: CGImage, size: NSSize, appearance: NSAppearance.Name?) async {
        guard size.width > 0 else { return }
        let data = await Task.detached(priority: Task.currentPriority) { frame.pageImageData() }.value
        removeHeld(key)
        guard let data, heldLimit > 0 else { return }
        held[key] = HeldFrame(data: data, size: size, appearance: appearance, order: nextHeldOrder)
        nextHeldOrder += 1
        heldBytes += data.count
        while held.count > heldLimit { dropOldestHeld() }
    }

    /// Holds `data`, tab `key`'s frame encoded already (the picture its page took as it hid, kept by the
    /// page lifecycle), as ``hold(_:_:size:appearance:)`` holds one.
    public func hold(_ key: String, encoded data: Data, size: NSSize, appearance: NSAppearance.Name?) {
        removeHeld(key)
        guard size.width > 0, heldLimit > 0 else { return }
        held[key] = HeldFrame(data: data, size: size, appearance: appearance, order: nextHeldOrder)
        nextHeldOrder += 1
        heldBytes += data.count
        while held.count > heldLimit { dropOldestHeld() }
    }

    /// The tab closed or showed its live page: its held frame goes.
    public func drop(_ key: String) {
        removeHeld(key)
    }

    /// Takes `key`'s held frame out, keeping ``heldBytes``.
    @discardableResult
    private func removeHeld(_ key: String) -> HeldFrame? {
        guard let frame = held.removeValue(forKey: key) else { return nil }
        heldBytes -= frame.data.count
        return frame
    }

    /// Drops the oldest held frame (at most ``maximumFiles`` to look through).
    private func dropOldestHeld() {
        guard let oldest = held.min(by: { $0.value.order < $1.value.order })?.key else { return }
        removeHeld(oldest)
    }

    /// Registers the held frames and the launch read with the app's memory coordinator, one lossy consumer;
    /// a later call replaces the registration.
    ///
    /// - Parameter registry: The memory coordinator (injected).
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration?.cancel()
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
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
        await Task.detached(priority: Task.currentPriority) { Self.write(frames.compactMapValues { $0.pageImageData() }, to: directory) }.value
    }

    /// Every saved page in `directory`, decoded, with its point size, by tab key: for each key the first
    /// kind a save may have written (one at a time: a save replaces the set).
    private nonisolated static func readAll(in directory: URL, _ reader: LaunchFileReader) -> SavedPages {
        let names = Set(((try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().prefix(maximumFiles))
        var saved = SavedPages()
        for (scale, ext) in [2, 1, 3].flatMap({ scale in ["png", "jpg"].map { (scale, $0) } }) {
            let suffix = "@\(scale)x.\(ext)"
            for name in names where name.hasSuffix(suffix) {
                let key = String(name.dropLast(suffix.count))
                guard saved.pages[key] == nil, isFileSafe(key),
                      let page = reader.image(at: directory.appending(path: name), maximumBytes: maximumBytes) else { continue }
                saved.pages[key] = Page(image: page, size: NSSize(width: CGFloat(page.width) / CGFloat(scale), height: CGFloat(page.height) / CGFloat(scale)))
                saved.bytes += page.bytesPerRow * page.height
            }
        }
        return saved
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

/// The held frames and the launch read's untaken pages as one lossy consumer (Chrome's consumer contract,
/// base/memory_coordinator/memory_consumer.h): a new limit only lowers how many frames
/// ``hold(_:_:size:appearance:)`` keeps; ``releaseMemory(within:)`` drops down to it.
extension AgentPaneLaunchImages: MemoryConsumer {
    /// Encoded frames and, for 30 s after launch, decoded pages (1 to 50 MB); dropping them touches only
    /// memory and loses them (the pane shows its loading state instead), so only critical pressure acts.
    public nonisolated static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossy, recreateCost: .notApplicable,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The consumer's name in the memory report.
    public nonisolated static let memoryConsumerName = "agent-pane-launch-images"

    /// Lowers how many held frames the next hold keeps. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        heldLimit = limit.scale(Self.maximumFiles)
    }

    /// Below the full limit the launch read's untaken pages go first (a launch's one burst, dropped after
    /// 30 s anyway), then the oldest held frames, one at a time, until the limit holds or the slice is spent.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        if slice.limit < .default, read != nil { dropRead() }
        while held.count > heldLimit {
            if slice.isExpired { return .more }
            dropOldestHeld()
        }
        return .done
    }

    /// The held frames' encoded bytes and the launch read's decoded pages, from two counters.
    public var memoryUsage: MemoryUsage? {
        let saved = read?.value
        return MemoryUsage(footprintBytes: heldBytes + (saved?.bytes ?? 0), entries: held.count + (saved?.pages.count ?? 0))
    }
}
