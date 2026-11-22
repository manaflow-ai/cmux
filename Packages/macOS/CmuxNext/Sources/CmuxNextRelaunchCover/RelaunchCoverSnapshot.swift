public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings

/// One window the old process covers: its id, the window and each pane's view by pane id.
public struct RelaunchCoverSource {
    public var id: String
    public var window: NSWindow
    public var panes: [String: NSView]

    public init(id: String, window: NSWindow, panes: [String: NSView]) {
        self.id = id
        self.window = window
        self.panes = panes
    }
}

/// The old process's half of the relaunch cover (cmux-launch-shell `relaunch_cover`): at an update's relaunch
/// (before `UpdateWindowHandoff` hides the windows) or a quit that keeps sessions, each window on screen is captured
/// as the window server shows it, with its frame, display, stacking order, key state and the rect of each pane.
/// The pictures and the manifest are written off the main thread; the quit's `relaunch_cover` step waits for that
/// write within its limit. What the new process shows, and when it shows nothing, Rust decides.
@MainActor
public final class RelaunchCoverSnapshot {
    private let folder: URL?
    private var write: Task<Void, Never>?

    /// `folder`: the cover folder (``RelaunchCoverStore/folder(beside:)``), nil to never capture.
    public init(folder: URL?) {
        self.folder = folder
    }

    /// Captures `windows` (front first) now, once per process: an update's capture stands for its quit's. Nothing
    /// when off or when one window cannot be captured (all or nothing: the next launch opens every one).
    public func capture(_ cause: RelaunchCoverCause, swap: RelaunchCoverSwap, windows: [RelaunchCoverSource]) {
        guard write == nil, let folder, swap != .off else { return }
        var saved: [RelaunchCoverWindow] = []
        var images: [(name: String, image: CGImage)] = []
        for (index, source) in windows.enumerated() where Self.covers(source.window) {
            // The window server's image, on main: the update's hide comes right after this returns.
            guard let screen = source.window.screen, let plan = source.window.compositedCapturePlan(),
                  let image = NSWindow.capture(plan) else { return }
            let name = "\(source.id).png"
            images.append((name, image))
            saved.append(RelaunchCoverWindow(
                id: source.id, frame: RelaunchCoverRect(source.window.frame), screenFrame: RelaunchCoverRect(screen.frame),
                scale: Double(screen.backingScaleFactor), order: UInt32(index), key: source.window.isKeyWindow,
                fullscreen: source.window.styleMask.contains(.fullScreen), image: name, surfaces: Self.surfaces(of: source)))
        }
        guard !saved.isEmpty else { return }
        let manifest = RelaunchCoverManifest(cause: cause, writtenAtMs: Self.nowMs(), build: Self.build, windows: saved)
        // task-owner: the pictures' encode and write, awaited by the quit's relaunch_cover step (`finish`) under its limit.
        write = Task { [images] in await Self.write(manifest, images: images, to: folder) }
    }

    /// Waits for the write `capture` started, if any.
    public func finish() async {
        await write?.value
    }

    /// A window the cover stands in for: ordered in, not minimized, not already hidden for the quit. One behind
    /// another still counts: the restore opens it too, and its picture sits behind the other's.
    private static func covers(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.alphaValue > 0
    }

    /// The pane rects in the content view, top-left origin, in points.
    private static func surfaces(of source: RelaunchCoverSource) -> [RelaunchCoverSurface] {
        guard let content = source.window.contentView else { return [] }
        let height = content.bounds.height
        return source.panes.compactMap { id, view in
            guard view.window === source.window, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0
            else { return nil }
            let rect = view.convert(view.bounds, to: content)
            return RelaunchCoverSurface(id: id, rect: RelaunchCoverRect(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)))
        }.sorted { $0.id < $1.id }
    }

    /// Off the main thread: the PNG encodes, the files and Rust's manifest write.
    @concurrent
    private nonisolated static func write(_ manifest: RelaunchCoverManifest, images: [(name: String, image: CGImage)], to folder: URL) async {
        guard (try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        for (name, image) in images {
            guard (try? await NSWindow.encodeSnapshotPNG(image, to: folder.appendingPathComponent(name))) != nil else { return }
        }
        _ = RelaunchCoverStore.write(manifest, to: folder)
    }

    nonisolated static func nowMs() -> UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }

    private static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}
