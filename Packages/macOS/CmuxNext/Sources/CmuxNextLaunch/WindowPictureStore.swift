public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
import ImageIO
import UniformTypeIdentifiers

/// One picture per window, saved at quit, that the next launch shows as the window's first frame (p08-startup 3C,
/// tasks 058 and 059 read it). Chrome does this on Android: the restored tab's saved capture is its first frame
/// until the live page paints (`StartupPaintPreview`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java).
///
/// The quit takes each window's picture on the main thread (``capture(_:hiding:)``: the root view as AppKit draws
/// it, without the window's backdrop, which the launch shows live under the picture) and hands it here as a
/// ``Shot`` with the panes' own pictures (terminal frames, agent pages, browser pages: AppKit draws none of them)
/// and the regions that must show only the theme background (a Secure Input pane, a withheld page). Composing,
/// the HEIC encode and the writes run on the files lane.
///
/// On disk: `<profile>/<window>.heic` and its ``WindowPictureMeta`` `<window>.json` (written last, so a quit that
/// ends between them leaves a picture no launch reads), mode 0600 in folders of mode 0700. A save replaces the
/// whole set. A window that is incognito, full screen, on another Space, not on screen or hidden from screen
/// capture is never written (``Eligibility``).
///
/// ```swift
/// let store = WindowPictureStore(state: stateDirectory, work: work)
/// // At quit, on main: one draw per window, the panes' pictures the quit took already.
/// let shot = WindowPictureStore.shot(of: window, root: root, backdrop: root.backdropView, sidebar: root.sidebar,
///                                    panes: [.init(key: tab, area: pane.contentHost, content: .picture(frame, of: surface))],
///                                    facts: facts)
/// await store.save([shot].compactMap { $0 })   // composed, encoded and written on the files lane
/// ```
@MainActor
public final class WindowPictureStore {
    /// The folder of the saved pictures in the tag's state directory.
    public static let directoryName = "window-pictures"
    /// The most windows one save writes.
    nonisolated static let maximumWindows = 32
    nonisolated static let pictureExtension = "heic"
    nonisolated static let metaExtension = "json"

    /// Whether a window may leave a picture on disk at all.
    public nonisolated struct Eligibility: Sendable, Equatable {
        public var incognito: Bool
        /// Ordered in and not minimized.
        public var onScreen: Bool
        public var onActiveSpace: Bool
        public var fullScreen: Bool
        /// `NSWindow.sharingType == .none`: the person asked that it never be captured.
        public var hiddenFromCapture: Bool

        public init(incognito: Bool, onScreen: Bool, onActiveSpace: Bool, fullScreen: Bool, hiddenFromCapture: Bool) {
            (self.incognito, self.onScreen, self.onActiveSpace) = (incognito, onScreen, onActiveSpace)
            (self.fullScreen, self.hiddenFromCapture) = (fullScreen, hiddenFromCapture)
        }

        /// `window`'s facts now; `incognito` is the app's (an incognito window looks like any other to AppKit).
        @MainActor public init(window: NSWindow, incognito: Bool) {
            self.init(incognito: incognito, onScreen: window.isVisible && !window.isMiniaturized,
                      onActiveSpace: window.isOnActiveSpace, fullScreen: window.styleMask.contains(.fullScreen),
                      hiddenFromCapture: window.sharingType == .none)
        }

        /// A full-screen window or one on another Space opens elsewhere than its picture would show; the others
        /// must never reach the disk.
        public var allowsPicture: Bool { !incognito && onScreen && onActiveSpace && !fullScreen && !hiddenFromCapture }
    }

    /// An opaque color, 0...1 components (the theme background of the fills).
    public nonisolated struct Color: Sendable, Equatable {
        public var red: Double, green: Double, blue: Double

        public init(red: Double, green: Double, blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }
    }

    /// A pane's own picture, drawn at its frame over the root view's drawing.
    public nonisolated struct Layer: Sendable {
        public let image: CGImage
        /// In points from the window content's top-left corner.
        public let frame: CGRect

        public init(image: CGImage, frame: CGRect) {
            (self.image, self.frame) = (image, frame)
        }
    }

    /// One window at quit, as the main thread captured it; composed and encoded on the files lane.
    public nonisolated struct Shot: Sendable {
        public let eligibility: Eligibility
        /// The root view as AppKit drew it, without the backdrop (``capture(_:hiding:)``).
        public let base: CGImage
        /// The root view's size in points (`base` is at the window's backing scale).
        public let size: CGSize
        /// The panes' own pictures, in order.
        public let layers: [Layer]
        /// Regions filled with `background` over everything else: content that must never reach the disk.
        public let fills: [CGRect]
        public let background: Color
        public let meta: WindowPictureMeta

        public init(eligibility: Eligibility, base: CGImage, size: CGSize, layers: [Layer], fills: [CGRect],
                    background: Color, meta: WindowPictureMeta) {
            (self.eligibility, self.base, self.size, self.layers) = (eligibility, base, size, layers)
            (self.fills, self.background, self.meta) = (fills, background, meta)
        }
    }

    let directory: URL?
    private let work: BackgroundWork
    private let encode: @Sendable (CGImage) -> Data?
    /// The launch's read of the front window's picture (WindowPictureStore+LaunchRead.swift).
    let launch: FrontRead

    /// - Parameters:
    ///   - directory: The saved pictures' folder; nil keeps none.
    ///   - work: The app's blocking-work lanes: composing, the encode and the writes run on its files lane.
    ///   - encode: Encodes a composed picture; default HEIC (tests record where it runs).
    ///   - reader: Reads the launch's files; default from disk (tests record where it runs, or hold it).
    public init(directory: URL?, work: BackgroundWork, encode: @escaping @Sendable (CGImage) -> Data? = { WindowPictureStore.heic($0) },
                reader: LaunchFileReader = LaunchFileReader()) {
        self.directory = directory
        self.work = work
        self.encode = encode
        launch = FrontRead(directory: directory, work: work, reader: reader)
    }

    /// The pictures in `state`, the tag's state directory (beside its launch snapshot).
    /// `reader` reads the launch's files; the app's skips every one in a crash streak's safe launch (`LaunchSafeMode`).
    public convenience init(state: URL?, work: BackgroundWork, reader: LaunchFileReader = LaunchFileReader()) {
        self.init(directory: state?.appending(path: Self.directoryName, directoryHint: .isDirectory), work: work, reader: reader)
    }

    /// `root` as AppKit draws it now, at its window's backing scale, with `backdrop` (the window's material and
    /// tint) left out: transparent where only the backdrop showed. Layers AppKit does not draw (Metal terminals,
    /// Chromium pages) come out as what lies under them; the quit draws the panes' own pictures over them.
    /// The backdrop is shown again before this returns, in the same turn, so no frame shows it hidden.
    public static func capture(_ root: NSView, hiding backdrop: NSView?) -> CGImage? {
        let bounds = root.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let hides = backdrop.map { !$0.isHidden && $0.isDescendant(of: root) } ?? false
        if hides { backdrop?.isHidden = true }
        root.cacheDisplay(in: bounds, to: rep)
        if hides { backdrop?.isHidden = false }
        return rep.cgImage
    }

    /// Replaces the saved pictures with `shots`' (only the ones their ``Eligibility`` allows); with none, the
    /// folder goes.
    public func save(_ shots: [Shot]) async {
        guard let directory else { return }
        let encode = encode
        _ = try? await work.run(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { Self.write(shots, to: directory, encode: encode) }
    }

    /// Deletes every saved picture (the feature off, Clear Browsing Data, a profile deleted).
    public func removeAll() async {
        await save([])
    }

    /// Follows `launch.savedPicture` (p08-startup 3C: the pictures are deleted with it off): each time `savedPicture`
    /// reads off, every saved picture is deleted on the files lane at once, not at the next quit, so a crash or a
    /// force quit after the change leaves no terminal text or page on disk. A launch that loads it off deletes any
    /// the last run left. The quit's save stays the backstop (``saveAtQuit(featureOn:savedPicture:_:)``).
    ///
    /// - Parameters:
    ///   - savedPicture: Reads the setting; nil until the settings first load (the person's choice is not known).
    ///   - mainWork: The app's main-thread scheduler.
    /// - Returns: The follower; the caller keeps it for as long as the setting is followed (the app's life).
    public func followSavedPicture(_ savedPicture: @escaping @MainActor () -> Bool?, on mainWork: MainWorkScheduler) -> ServiceObservation<Bool?> {
        // `background`: nothing on screen waits for the delete.
        ServiceObservation(.background, owner: "WindowPictureStore.savedPicture", on: mainWork, read: savedPicture) { [weak self] on in
            if on == false { self?.removeAllSoon() }
        }
    }

    /// ``removeAll()`` queued on the files lane, returning at once.
    private func removeAllSoon() {
        guard let directory else { return }
        work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { Self.write([], to: directory, encode: { _ in nil }) }
    }

    /// The quit's save (p08-startup 3C): `shots` is asked and its pictures saved only with the `savedWindowPicture`
    /// feature on and `launch.savedPicture` on; otherwise every saved picture is deleted and `shots` is not asked
    /// (no window is drawn for a picture nobody may keep).
    ///
    /// - Parameters:
    ///   - featureOn: The `savedWindowPicture` feature.
    ///   - savedPicture: `launch.savedPicture`; nil when the settings have not loaded, so the person's choice is not
    ///     known and nothing is kept.
    ///   - shots: The windows' shots, taken on main.
    public func saveAtQuit(featureOn: Bool, savedPicture: Bool?, _ shots: () -> [Shot]) async {
        await save(Self.keepsPicturesAtQuit(featureOn: featureOn, savedPicture: savedPicture) ? shots() : [])
    }

    /// Whether a quit keeps window pictures (``saveAtQuit(featureOn:savedPicture:_:)``).
    nonisolated static func keepsPicturesAtQuit(featureOn: Bool, savedPicture: Bool?) -> Bool {
        featureOn && savedPicture == true
    }

    /// Composes, encodes and writes `shots` by profile, replacing whatever the folder held.
    nonisolated static func write(_ shots: [Shot], to directory: URL, encode: (CGImage) -> Data?) {
        var byProfile: [String: [(meta: WindowPictureMeta, data: Data)]] = [:]
        var windows: Set<String> = []
        for shot in shots where shot.eligibility.allowsPicture && isFileSafe(shot.meta.window) && isFileSafe(shot.meta.profile) {
            guard windows.count < maximumWindows, !windows.contains(shot.meta.window),
                  let picture = compose(shot), let data = encode(picture) else { continue }
            windows.insert(shot.meta.window)
            byProfile[shot.meta.profile, default: []].append((shot.meta, data))
        }
        let manager = FileManager.checked
        try? manager.removeItem(at: directory)
        guard !byProfile.isEmpty else { return }
        for (profile, files) in byProfile {
            let folder = directory.appending(path: profile, directoryHint: .isDirectory)
            guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for file in files {
                guard let meta = try? encoder.encode(file.meta),
                      writePrivate(file.data, to: folder.appending(path: "\(file.meta.window).\(pictureExtension)")) else { continue }
                // The meta last: a picture without one is never shown.
                _ = writePrivate(meta, to: folder.appending(path: "\(file.meta.window).\(metaExtension)"))
            }
        }
    }

    /// The window's picture: `base` with each layer drawn at its frame, then the fills over them, at `base`'s
    /// pixel size. Transparent where only the backdrop showed.
    nonisolated static func compose(_ shot: Shot) -> CGImage? {
        let base = shot.base
        guard base.width > 0, base.height > 0, shot.size.width > 0, shot.size.height > 0,
              let context = canvas(width: base.width, height: base.height, space: base.colorSpace) else { return nil }
        let scale = CGFloat(base.width) / shot.size.width
        let height = CGFloat(base.height)
        // Points from the top-left corner to pixels from the bottom-left one (Core Graphics).
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for layer in shot.layers where layer.frame.width > 0 && layer.frame.height > 0 {
            context.draw(layer.image, in: pixels(layer.frame))
        }
        let fill = shot.background
        context.setFillColor(CGColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        for rect in shot.fills where rect.width > 0 && rect.height > 0 { context.fill(pixels(rect)) }
        return context.makeImage()
    }

    /// An 8-bit RGBA canvas in `space` (the window's colors), or in sRGB when `space` is not one an 8-bit RGBA
    /// context takes (an extended-range or non-RGB space).
    nonisolated static func canvas(width: Int, height: Int, space: CGColorSpace?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let space, space.model == .rgb,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) {
            return context
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)
    }

    /// `image` as HEIC (alpha kept: the launch shows the live backdrop through it); nil where ImageIO has no HEIC
    /// encoder.
    public nonisolated static func heic(_ image: CGImage, quality: Double = 0.75) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard blockingImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes `data` atomically with mode 0600; whether it was written.
    private nonisolated static func writePrivate(_ data: Data, to url: URL) -> Bool {
        guard (try? data.blockingWrite(to: url, options: [.atomic])) != nil else { return false }
        try? FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Window and profile ids are UUIDs or slugs; anything else never becomes a path.
    nonisolated static func isFileSafe(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
