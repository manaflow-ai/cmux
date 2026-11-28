public import AppKit
import CCmuxLaunchShellFFI
import CCmuxLayoutCacheFFI
import CmuxNextCompat
public import CmuxNextWakeups
import ImageIO

/// Stage 0 of the launch (cmuxterm-hq docs/design/launch-shell-first.md, "Decision: stage 0 is its
/// own window"): a plain window made in `applicationDidFinishLaunching` before the Cloud environment
/// and the app's services, at the front saved window's frame, showing its last committed image (or
/// the bare launch's content; never a plain fill: with neither it makes no window), in one commit. The real launch window is built as
/// before (`LaunchSnapshotWindow`, `WindowManager.makeController`), takes this window's frame and
/// orders in above it; this window closes at the real one's first commit, and the input it held is
/// posted to the real one in order. What it shows and holds is decided in Rust (cmux-launch-shell).
/// It reads the launch record and one image file and calls AppKit: no process, socket, settings or services.
@MainActor
public final class LaunchShell {
    /// The bare launch's content and its typed text's handoff; set before `show`.
    public var content = LaunchShellContent()

    /// How long stage 0 stays up with no real window ordered in.
    public static let backstop: Duration = .seconds(5)

    private let prepared: Prepared?
    /// The layout cache this launch read, gated by `usable` (cmux-layout-cache): the real windows'
    /// frames, sidebars and splits as they last drew, so the first frame is the final one. Read in
    /// `prepare`, before the first commit; nil when there is none or nothing in it applies.
    public private(set) var layoutCache: LayoutCacheLaunch?
    private let mark: @Sendable (String) -> Void
    /// The stage-0 window while it is up.
    public private(set) var window: LaunchShellWindow?
    private var framedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFramed = false
    private let backstopTimer = DemandTimer(owner: "LaunchShell.backstop")
    private let framedTimer = DemandTimer(owner: "LaunchShell.framed")
    private let bareTimer = DemandTimer(owner: "LaunchShell.bareBound")
    private let contentTimer = DemandTimer(owner: "LaunchShell.contentBound")
    /// Stage 0 shows the bare launch's content (its swap waits for Home: `presented`).
    private var showsBare = false
    /// Stage 0 drew the saved image, so a held click aimed at a place in it (`replays`).
    private var showedImage = false
    /// The real window did not take stage 0's place (or none was there at the dismissal): held
    /// clicks aimed at nothing it shows, so only keys replay.
    private var mismatched = false
    /// True once the real window showed what stage 0's image did (`contentReady`): only then do clicks on
    /// the image replay into it. Equal frames alone are not enough (a connecting view, a timed-out wait).
    private var contentMatched = false
    private var shownAt = ContinuousClock.now
    /// Held input with no real window to take it yet (stage 0 was dismissed first).
    private var heldForReal: [NSEvent] = []
    /// The real launch window, once ordered in: a hold that reaches its swap point swaps to it.
    private weak var real: NSWindow?

    private init(prepared: Prepared?, layoutCache: LayoutCacheLaunch? = nil, mark: @escaping @Sendable (String) -> Void) {
        self.prepared = prepared
        self.layoutCache = layoutCache
        self.mark = mark
    }

    /// Stage 0 for this launch, from the app's bundle id (its Application Support folder and
    /// Info.plist build); nil (an agent launch, a test window, an update relaunch behind) shows nothing.
    /// `session` is the daemon session name: with it, stage 0 shows no image of another session's windows.
    public static func atLaunch(bundleID: String?, session: String?, mark: @escaping @Sendable (String) -> Void) -> LaunchShell {
        guard let bundleID, let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return LaunchShell(prepared: nil, mark: mark)
        }
        return prepare(support: support.appending(path: bundleID, directoryHint: .isDirectory), appSupport: support, session: session,
                       build: LaunchShellPaths.build(info: Bundle.main.infoDictionary ?? [:]), mark: mark)
    }

    /// Reads the plan (one ≤64 KiB file, 24 bytes of the image, and one stat for an earlier run's
    /// state) and starts the image's decode on its own queue. In `main`, after
    /// `NSApplication.shared`; nothing waits for it. `launch_shell.plan_start` and `plan_ready` time
    /// the read. `support` is the app's Application Support folder (the launch record's, the image
    /// store's, and `launch-times.jsonl`); `appSupport` (Library/Application Support) and `session`
    /// name the registry id this home last saw live, nil for no session check.
    public static func prepare(support: URL, appSupport: URL? = nil, session: String? = nil, build: String,
                               mark: @escaping @Sendable (String) -> Void) -> LaunchShell {
        let displays = NSScreen.screens.map { screen in
            CmuxLaunchShellDisplay(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                                   height: screen.frame.height, scale: screen.backingScaleFactor)
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        mark("launch_shell.plan_start")
        var plan = CmuxLaunchShellPlan()
        let read = build.withCString { build in support.path.withCString { supportDir in
            (appSupport?.path).withOptionalCString { appSupport in session.withOptionalCString { session in
                displays.withUnsafeBufferPointer { displays in
                    var now = CmuxLaunchShellNow(build: build, appearance: dark ? 1 : 0, displays: displays.baseAddress, display_count: displays.count,
                                                 support_dir: supportDir, app_support: appSupport, daemon_session: session)
                    return cmux_launch_shell_plan(LaunchShellPaths.record(in: support).path, LaunchShellPaths.images(in: support).path, &now, &plan)
                }
            } }
        } }
        mark("launch_shell.plan_ready")
        let layoutCache = LayoutCacheLaunch.read(support: support, build: build)
        mark(layoutCache == nil ? "layout_cache.none" : "layout_cache.read")
        guard read, plan.shows_window else { return LaunchShell(prepared: nil, layoutCache: layoutCache, mark: mark) }
        // A plan with no saved window carries no colours (all zero): stage 0 then paints the layout
        // cache's last theme, and with neither it makes no window, since a guessed colour (opaque black)
        // flashed to the real theme on the first frame (startup video at e77af242).
        let cachedLook = layoutCache?.front.map { LaunchShellLook(cached: $0) }
        guard Prepared.hasLook(plan) || cachedLook != nil else {
            mark("launch_shell.none_unknown_look")
            return LaunchShell(prepared: nil, layoutCache: layoutCache, mark: mark)
        }
        let prepared = Prepared(plan: plan, cachedFrame: layoutCache?.front.flatMap { layoutCache?.frame(for: $0.id) }, cachedLook: cachedLook)
        if let path = prepared.imagePath { prepared.decode(path, mark: mark) }
        return LaunchShell(prepared: prepared, layoutCache: layoutCache, mark: mark)
    }

    /// Makes the window and commits its first frame, marking `launch_shell.committed` when the
    /// commit completes (`first_window_frame_committed` stays the real window's). Does nothing when
    /// the plan made no window.
    public func show(title: String) {
        guard let prepared else { return framedNow() }
        let frame = prepared.frame
        let image = prepared.image()
        let bare = image == nil && prepared.usesDefaultFrame
            ? content.bare?(CGRect(origin: .zero, size: frame.size), prepared.look) : nil
        guard image != nil || bare != nil else {
            // No picture to show (not decoded in time, or none planned): no window. An empty one in
            // the saved colours is an opaque cover over where the real window will be, not the window
            // as it was (Leo, 2026-11-27: "stop putting the opaque thing from the start"); the real
            // window, drawn from saved state, is the first frame.
            mark(prepared.imagePath == nil ? "launch_shell.none_no_picture" : "launch_shell.none_image_late")
            return framedNow()
        }
        shownAt = .now
        let window = LaunchShellWindow(contentRect: frame, title: title)
        window.backgroundColor = prepared.look.background
        window.appearance = NSAppearance(named: prepared.look.dark ? .darkAqua : .aqua)
        let view: NSView
        let kind: String
        if let image {
            view = LaunchShellImageView(image: image, scale: window.backingScaleFactor)
            kind = "image"
        } else {
            view = bare ?? NSView()
            kind = "bare"
        }
        window.onSwapNeeded = { [weak self] in if let self, let real = self.real { self.swap(to: real) } }
        // One explicit transaction: it commits at `commit()`, before this turn's other work.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setMainCompletion { [weak self, mark] in
            mark("launch_shell.committed")
            self?.framedNow()
        }
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFront(nil)
        FocusRoute(.system, "stage 0 is the launch's only window; the real one takes key at the swap").makeKey(window)
        CATransaction.commit()
        self.window = window
        showsBare = kind == "bare"
        showedImage = kind == "image"
        window.holdsInput = !showsBare
        mark("launch_shell.\(kind)")
        backstopTimer.schedule(after: Self.backstop) { @MainActor [weak self] in self?.dismiss() }
    }

    /// Returns once stage 0's frame is committed (at once when it made no window), or 100 ms after
    /// the call at the latest, so a commit that never completes holds nothing.
    public func framed() async {
        guard !isFramed else { return }
        framedTimer.schedule(after: .milliseconds(100)) { @MainActor [weak self] in self?.framedNow() }
        await withCheckedContinuation { framedWaiters.append($0) }
    }

    private func framedNow() {
        guard !isFramed else { return }
        isFramed = true
        framedTimer.cancel()
        let waiters = framedWaiters
        framedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// The frame the real launch window takes while this one is up (nil: none is up).
    public var frame: CGRect? { window?.frame }

    /// How long after `show` a bare stage 0 waits for Home (`LaunchShellContent.bareReady`)
    /// before it swaps to whatever the real window shows.
    public static let bareBound: Duration = .milliseconds(1500)

    /// The first real window ordered in: it takes this window's frame before its first commit, so
    /// it never draws elsewhere. Ordered above this one, it takes over at that commit (`swap`). Under
    /// the bare launch's content it goes below instead, never key, and takes over once Home is up
    /// in it (`bareReady`) or at `bareBound`: its connecting view is never seen. Only the bare
    /// kind waits below: the real window shows native Home there, nothing that stops drawing
    /// when covered (a terminal, a Chromium page).
    public func presented(_ real: NSWindow?) {
        guard let real, self.real == nil else { return }
        self.real = real
        // Stage 0 went first (the backstop): what it held goes to this window now.
        guard let frame, let window else { return replay(to: real) }
        if real.frame != frame { real.setFrame(frame, display: false) }
        // Over the saved image the real window waits below until what it shows
        // matches stage 0 (every visible region has its saved or live content: `contentReady`), at
        // most the Rust bound (cmux-layout-cache `swap_wait_ms`), so the swap shows no blank pane
        // filling in afterwards (Leo, 2026-11-24: "it's another to say \"ok it's already loaded\"").
        if !showsBare, let contentReady = content.contentReady {
            real.order(.below, relativeTo: window.windowNumber)
            let kind: UInt8 = showedImage ? 0 : 1
            let elapsed = { [shownAt] in UInt64(max(0, shownAt.duration(to: .now) / .milliseconds(1))) }
            var swapped = false
            let swapOnce: @MainActor (String) -> Void = { [weak self, weak real] reason in
                guard !swapped, let self, let real, self.window != nil else { return }
                swapped = true
                self.contentMatched = reason == "ready"
                self.contentTimer.cancel()
                self.mark("launch_shell.content_\(reason)")
                self.swap(to: real, front: true)
            }
            let wait = cmux_layout_cache_swap_wait_ms(kind, 1, 0, elapsed())
            contentTimer.schedule(after: .milliseconds(Int(wait))) { @MainActor in swapOnce("timeout") }
            contentReady { swapOnce("ready") }
            return
        }
        guard showsBare, let bareReady = content.bareReady else {
            CATransaction.setMainCompletion { [weak self, weak real] in if let real { self?.swap(to: real) } }
            return
        }
        real.order(.below, relativeTo: window.windowNumber)
        FocusRoute(.system, "the bare launch's content keeps the keys until Home is up in the real window").makeKey(window)
        let left = Self.bareBound - shownAt.duration(to: ContinuousClock.now)
        bareTimer.schedule(after: max(.zero, left)) { @MainActor [weak self, weak real] in
            guard let self, let real, self.window != nil else { return }
            mark("launch_shell.bare_timeout")
            swap(to: real, front: true)
        }
        bareReady { [weak self, weak real] in
            guard let self, let real, self.window != nil else { return }
            bareTimer.cancel()
            swap(to: real, front: true)
        }
    }

    /// The real launch window took over: this one goes, and the input it held is posted to `real`
    /// in arrival order (`replay`). `front`: `real` waited below this one.
    public func swap(to real: NSWindow, front: Bool = false) {
        if front { FocusRoute(.system, "the real launch window takes over from stage 0").makeKey(real, front: true) }
        dismiss(swappedTo: real)
        replay(to: real)
    }

    /// Posts the held input to `real`, in arrival order: every key, and a click, drag or scroll
    /// only when it aimed at the saved image and `real` took its place (Rust `replays`).
    private func replay(to real: NSWindow) {
        guard !heldForReal.isEmpty else { return }
        let held = heldForReal
        heldForReal.removeAll()
        for event in held where cmux_launch_shell_replays(LaunchShellReplay.kind(event), showedImage, mismatched) {
            if let moved = LaunchShellReplay.event(event, to: real) { NSApp.postEvent(moved, atStart: false) }
        }
    }

    /// Closes the window (the backstop, or the swap). Its held input waits for the real window
    /// (`swap`, or `presented` after a backstop): nothing typed is dropped.
    public func dismiss(swappedTo real: NSWindow? = nil) {
        guard let window else { return }
        self.window = nil
        backstopTimer.cancel()
        if showsBare, let view = window.contentView { content.handoff?(view) }
        heldForReal += window.takeHeld()
        mismatched = real?.frame != window.frame || !contentMatched
        let kind = real == nil ? "dismissed" : mismatched ? "swapped.mismatch" : "swapped"
        window.orderOut(nil)
        window.close()
        mark("launch_shell.\(kind)")
    }
}

/// What the bare launch lane plugs into stage 0.
@MainActor public struct LaunchShellContent {
    /// Content for a launch with nothing to restore: the window's content view at `frame` (window
    /// coordinates), or nil for no stage-0 window.
    public var bare: ((_ frame: CGRect, _ look: LaunchShellLook) -> NSView?)?
    /// Calls `ready` (on the main actor, once) when the real window shows Home with its composer
    /// (the bare lane's marks); the swap waits for it, at most `LaunchShell.bareBound` after
    /// `show`. Nil: the swap is at the real window's first commit.
    public var bareReady: ((_ ready: @escaping @MainActor () -> Void) -> Void)?
    /// Calls `ready` (on the main actor, once) when the real window's visible regions (sidebar,
    /// tab strips, panes) have their saved or live content, so it looks as stage 0's image does;
    /// over the image the swap waits for it, at most the Rust bound. Nil: the
    /// swap is at the real window's first commit.
    public var contentReady: (@MainActor (_ ready: @escaping @MainActor () -> Void) -> Void)?
    /// Called with `bare`'s view at the swap, before stage 0 closes: the bare lane takes what was
    /// typed and sent into it (its own store; the real Home claims it).
    public var handoff: ((NSView) -> Void)?

    public init() {}
}

/// The plan's colors and appearance, for the plain shell and the bare launch's content.
public struct LaunchShellLook {
    public let background: NSColor
    public let bar: NSColor
    public let dark: Bool

    public init(background: NSColor, bar: NSColor, dark: Bool) {
        self.background = background; self.bar = bar; self.dark = dark
    }

    /// The layout cache's last look of `window`: its theme's backdrop and bar, and its appearance.
    init(cached window: LayoutCacheWindow) {
        let color = { (c: [UInt8]) -> NSColor in
            guard c.count == 4 else { return .windowBackgroundColor }
            return NSColor(srgbRed: CGFloat(c[0]) / 255, green: CGFloat(c[1]) / 255, blue: CGFloat(c[2]) / 255, alpha: c[3] == 0 ? 1 : CGFloat(c[3]) / 255) // colour-allow: the saved theme's own colors from the layout cache, before the theme loads
        }
        self.init(background: color(window.theme.backgroundRgba), bar: color(window.theme.barRgba), dark: window.appearance == .dark)
    }
}

/// The launch record's and the image store's paths in the app's Application Support folder.
public struct LaunchShellPaths {
    public init() {}
    public static func record(in support: URL) -> URL { support.appending(path: "launch-record.bin", directoryHint: .notDirectory) }
    public static func images(in support: URL) -> URL { support.appending(path: "launch-images", directoryHint: .isDirectory) }

    /// The first part of every image key, from the bundle's version and commit: a new build never
    /// draws an old build's image. Only characters a key component allows (cmux-launch-shell `ImageKey`).
    public nonisolated static func build(info: [String: Any]) -> String {
        let raw = [info["CFBundleVersion"] as? String, info["CMUXCommit"] as? String].compactMap { $0 }.joined(separator: "+")
        let kept = raw.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".+_-".unicodeScalars.contains($0)) }
        return kept.isEmpty ? "unknown" : String(String.UnicodeScalarView(kept.prefix(128)))
    }
}

/// The plan, and the image decoded on its own queue (never the launch reads' lane).
@MainActor private final class Prepared {
    let frame: CGRect
    let look: LaunchShellLook
    let reason: UInt8
    /// Nothing to restore (a fresh install, or no window at the last quit): the bare launch's content.
    let usesDefaultFrame: Bool
    let imagePath: String?
    private let decoded = DecodedImage()

    /// The plan carries the saved window's colours (a plan with no saved window leaves them all zero).
    static func hasLook(_ plan: CmuxLaunchShellPlan) -> Bool {
        plan.background_rgba != (0, 0, 0, 0) || plan.bar_rgba != (0, 0, 0, 0)
    }

    /// `cachedFrame`: the layout cache's front window, where the real window opens when the
    /// launch record has no frame (`WindowManager.makeController`): stage 0 stands at the same place.
    /// `cachedLook`: that window's last theme, painted when the plan carries no colours.
    init(plan: CmuxLaunchShellPlan, cachedFrame: CGRect? = nil, cachedLook: LaunchShellLook? = nil) {
        var plan = plan
        if plan.uses_default_frame, let cachedFrame {
            frame = cachedFrame
        } else if plan.uses_default_frame {
            // The real window's own default (1100 x 720, centered): the swap cannot jump.
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            frame = CGRect(x: visible.midX - 550, y: visible.midY - 360, width: 1100, height: 720).integral
        } else {
            frame = CGRect(x: plan.frame_x, y: plan.frame_y, width: plan.frame_width, height: plan.frame_height)
        }
        let color = { (c: (UInt8, UInt8, UInt8, UInt8)) in
            NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: c.3 == 0 ? 1 : CGFloat(c.3) / 255) // colour-allow: the saved theme's own colors from the launch record, before the theme loads
        }
        let saved = LaunchShellLook(background: color(plan.background_rgba), bar: color(plan.bar_rgba), dark: plan.appearance == 1)
        look = Self.hasLook(plan) ? saved : cachedLook ?? saved
        reason = plan.reason
        usesDefaultFrame = plan.uses_default_frame
        let path = withUnsafeBytes(of: &plan.image_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        imagePath = plan.reason == 0 && !path.isEmpty ? path : nil
    }

    func decode(_ path: String, mark: @escaping @Sendable (String) -> Void) {
        // The first frame waits for it (or goes plain without it): above default, below the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [decoded] in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
            decoded.value.withLock { $0 = image }
            mark("launch_shell.image_decoded")
        }
    }

    /// The decoded image, if the decode finished: never waited for (a late image is not drawn,
    /// so the first frame never changes under the person).
    func image() -> CGImage? { decoded.value.withLock { $0 } }
}

/// The image the decode queue hands to the main thread.
private final class DecodedImage: Sendable {
    let value = Mutex<CGImage?>(nil)
}

/// The stage-0 window: the real window's style, not movable while it is up (under a second),
/// holding every key, button, drag and scroll for the real window.
public final class LaunchShellWindow: NSWindow {
    private var held: [NSEvent] = []
    /// Called when holding reaches its swap point.
    var onSwapNeeded: (() -> Void)?

    init(contentRect: CGRect, title: String) {
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        animationBehavior = .none
        minSize = NSSize(width: 520, height: 320)
    }

    /// False under the bare launch's content: it is live and takes its own input.
    var holdsInput = true

    override public func sendEvent(_ event: NSEvent) {
        guard holdsInput else { return super.sendEvent(event) }
        switch cmux_launch_shell_input_disposition(LaunchShellReplay.kind(event), held.count) {
        case 1: held.append(event)
        case 2: held.append(event); onSwapNeeded?()
        default: super.sendEvent(event)
        }
    }

    /// The held events, in arrival order; the window holds none after.
    func takeHeld() -> [NSEvent] {
        defer { held.removeAll() }
        return held
    }
}

/// The saved image at the window's backing scale, from its top-left corner (no scaling).
private final class LaunchShellImageView: NSView {
    init(image: CGImage, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsScale = scale
        layer?.contentsGravity = .topLeft
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// Held events, rebuilt for the real window (same frame, so the same window location).
public struct LaunchShellReplay {
    public init() {}
    /// The Rust `InputKind` of an event type.
    public static func kind(_ type: NSEvent.EventType) -> UInt8 {
        switch type {
        case .keyDown: 1
        case .keyUp: 2
        case .flagsChanged: 3
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: 4
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: 5
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: 6
        case .scrollWheel: 7
        case .mouseMoved, .mouseEntered, .mouseExited: 8
        default: 0
        }
    }

    static func kind(_ event: NSEvent) -> UInt8 { kind(event.type) }

    /// `event` as if it had arrived in `window`, or nil for a kind that is never held.
    public static func event(_ event: NSEvent, to window: NSWindow) -> NSEvent? {
        switch event.type {
        case .keyDown, .keyUp:
            return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                    timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                    characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                    isARepeat: event.isARepeat, keyCode: event.keyCode)
        case .flagsChanged:
            return NSEvent.keyEvent(with: .flagsChanged, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                    timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: event.keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                      timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
        case .scrollWheel:
            guard let copy = event.cgEvent?.copy() else { return nil }
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            return NSEvent(cgEvent: copy)
        default:
            return nil
        }
    }
}

extension Optional where Wrapped == String {
    /// `body` gets the string's C form for the call, or NULL for nil.
    fileprivate func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let self else { return body(nil) }
        return self.withCString { body($0) }
    }
}
