public import AppKit
import ImageIO
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups

/// The new process's half of the relaunch cover. At launch, before any window opens, it takes Rust's plan
/// (`RelaunchCoverStore.takePlan`): a stale or mismatched cover is never shown. A shown plan puts each window's
/// last picture on screen at once, at its saved frame and stacking order, in a borderless click-through window.
/// When the real window is on screen, the picture rides on it as a child window above it, and goes as its panes
/// report ready (`whenPainted`; a terminal shows its last frame from its first layout). Which part goes when, and
/// whether it fades, Rust decides (`RelaunchCoverReveal`); a 2.5 s deadline takes whatever is left, and a live
/// window that does not match its picture drops it at once.
@MainActor
public final class RelaunchCoverPresenter {
    public typealias WhenPainted = @MainActor (NSView, @escaping @MainActor () -> Void) -> Void

    private let folder: URL?
    private let whenPainted: WhenPainted
    private var plan: RelaunchCoverPlan?
    private var reveal: RelaunchCoverReveal?
    private var covers: [String: RelaunchCoverPanel] = [:]
    private var watched: Set<String> = []
    /// The saved pictures, decoded off main by `preload`, by file name; nil until that is done.
    private var images: [String: CGImage]?
    private var loading: Task<Void, Never>?
    private var began = false
    private let deadline = DemandTimer(owner: "RelaunchCoverPresenter.deadline")

    /// `whenPainted(view, done)`: calls `done` once every page in `view` painted its first frame.
    public init(folder: URL?, whenPainted: @escaping WhenPainted) {
        self.folder = folder
        self.whenPainted = whenPainted
    }

    /// Starts decoding the saved pictures off main, so `begin` finds them ready without a read on main. Call as
    /// early in the launch as it can run; a launch with no cover folder reads nothing.
    public func preload() {
        guard let folder, loading == nil else { return }
        // task-owner: the pictures' decode, read by `begin`; one per launch, it ends with the decode.
        loading = Task { [weak self] in
            let decoded = await Self.decode(in: folder)
            // A decode that ends after `begin` is dropped with the launch that wanted it.
            guard let self, !began else { return }
            images = decoded
        }
    }

    /// Takes the plan and shows its pictures. Call once per launch, before the first window opens. `restoring`: the
    /// ids of the windows this launch opens; `shows` false (windows already open, none ordered in) only lets the
    /// pictures go.
    public func begin(shows: Bool, swap: RelaunchCoverSwap, restoring: [String], mark: (String) -> Void) {
        // The decoded pictures are this call's alone: held past it they would keep tens of MB for the process's life.
        let images = self.images
        self.images = nil
        began = true
        guard shows, let folder else { return }
        let displays = NSScreen.screens.map { RelaunchCoverDisplay(frame: $0.frame, scale: Double($0.backingScaleFactor)) }
        guard let plan = RelaunchCoverStore.takePlan(in: folder, nowMs: RelaunchCoverSnapshot.nowMs(), displays: displays, restoring: restoring)
        else { return }
        mark("relaunch_cover.\(plan.reason)")
        // Off: the manifest is taken all the same, so a cover never outlives the launch after it.
        guard plan.shows, let style = swap.style, let reveal = RelaunchCoverReveal(plan: plan, style: style, openedMs: Self.uptimeMs())
        else { return RelaunchCoverStore.clear(plan, in: folder) }
        // Pictures not decoded yet: no cover rather than a read on main or a picture after the window.
        guard let images, plan.windows.allSatisfy({ images[Self.name($0.imagePath)] != nil }) else {
            mark("relaunch_cover.not_decoded")
            return RelaunchCoverStore.clear(plan, in: folder)
        }
        self.plan = plan
        self.reveal = reveal
        // Back to front, so the front picture ends on top.
        for planned in plan.windows.reversed() {
            guard let image = images[Self.name(planned.imagePath)] else { return finish() }
            let cover = RelaunchCoverPanel(frame: planned.frame.rect, image: image, surfaces: planned.surfaces)
            covers[planned.id] = cover
            cover.orderFront(nil)
        }
        mark("relaunch_cover.shown")
        apply(reveal.start())
        if self.reveal != nil { scheduleDeadline() }
    }

    /// The real window `id` is on screen: its picture rides on it, and each pane (`panes`, by pane id) reports ready
    /// once it painted.
    public func windowShown(id: String, window: NSWindow, panes all: [String: NSView]) {
        // As the capture counted them: a hidden pane (another screen of the workspace) has no picture part.
        let panes = all.filter { !$0.value.isHiddenOrHasHiddenAncestor }
        guard let reveal, let cover = covers[id], window.isVisible, let planned = plan?.windows.first(where: { $0.id == id }),
              watched.insert(id).inserted else { return }
        if cover.parent == nil { window.addChildWindow(cover, ordered: .above) }
        // Another layout, size or workspace than the picture's: keeping it up would be the jump it exists to hide.
        guard Self.same(window.frame, planned.frame.rect), Set(panes.keys) == Set(planned.surfaces.map(\.id)) else {
            return apply(reveal.mismatch(window: id))
        }
        for (surface, view) in panes {
            whenPainted(view) { [weak self] in
                guard let self, let reveal = self.reveal else { return }
                apply(reveal.surfaceReady(window: id, surface: surface, nowMs: Self.uptimeMs()))
            }
        }
    }

    private func apply(_ steps: [RelaunchCoverStep]) {
        for step in steps {
            guard let cover = covers[step.window] else { continue }
            switch step {
            case .surface(_, let surface, let fadeMs):
                cover.fadeSurface(surface, fades: fadeMs > 0)
            case .window(let window, let fadeMs):
                covers[window] = nil
                cover.fadeOut(fades: fadeMs > 0)
            }
        }
        if covers.isEmpty, reveal != nil { finish() }
    }

    private func scheduleDeadline() {
        guard let reveal, let next = reveal.tick(nowMs: Self.uptimeMs()).next else { return }
        let now = Self.uptimeMs()
        deadline.schedule(after: .milliseconds(Int(next > now ? next - now : 0))) { @MainActor [weak self] in
            guard let self, let reveal = self.reveal else { return }
            let tick = reveal.tick(nowMs: Self.uptimeMs())
            apply(tick.steps)
            if tick.next != nil { scheduleDeadline() }
        }
    }

    private func finish() {
        deadline.cancel()
        for cover in covers.values { cover.fadeOut(fades: false) }
        covers = [:]
        if let plan, let folder { RelaunchCoverStore.clear(plan, in: folder) }
        plan = nil
        reveal = nil
    }

    /// Off the main thread: every PNG in the folder, decoded now, so drawing it later reads nothing.
    @concurrent
    private nonisolated static func decode(in folder: URL) async -> [String: CGImage] {
        let files = (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var images: [String: CGImage] = [:]
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for file in files where file.pathExtension == "png" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { continue }
            images[file.lastPathComponent] = image
        }
        return images
    }

    private nonisolated static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    static func uptimeMs() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }
}

extension RelaunchCoverSwap {
    /// The reveal's style; nil when off.
    var style: RelaunchCoverStyle? {
        switch self {
        case .off: nil
        case .instant: .instant
        case .crossfade: .crossfade
        case .progressive: .progressive
        }
    }
}
