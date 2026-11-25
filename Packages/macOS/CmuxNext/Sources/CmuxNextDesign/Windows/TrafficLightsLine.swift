public import AppKit
import CmuxNextCompat

/// The traffic lights on the top row's line (Austin 2026-11-10: "We need to make sure that the traffic
/// lights are aligned to the densities as well (will need to adjust them as well according to which
/// density the user selects)").
///
/// macOS centers the lights in its titlebar, 16 pt below the window's top at every density. The
/// concentric top row (``TopRowLineLook/concentric``, the default) centers the tab pills, the toolbar
/// band and the sidebar's + on the pills' line, which moves down as the density grows (20 pt at
/// Compact, 21.5 pt at Default). The lights move onto that line, so the whole top row shares it. With
/// no such line (a standard titlebar, tab bars at the bottom, and the `lights` and `off` variants,
/// whose line is the lights' own) they go back to macOS's place. Either way the close button sits as far
/// from the window's left edge as from its top (Lawrence 2026-11-10: "make sure top land left are even"),
/// the way macOS places it in its own titlebar (9 pt and 9 pt), so the lights keep the corner's proportion.
@MainActor
public struct TrafficLightsLine {
    public init() {}

    /// Where the lights' container is and where the buttons sit in it.
    public nonisolated struct Placement: Equatable, Sendable {
        /// The container's height, from the window's top edge.
        public var containerHeight: CGFloat
        /// The buttons' center, from the window's top edge.
        public var centerY: CGFloat
        /// The close button's left edge, from the window's left edge: its top edge's inset.
        public var leadingX: CGFloat
    }

    /// The placement for buttons `buttonHeight` tall centered `centerY` below the window's top, in a
    /// container macOS made `nativeHeight` tall at the window's top. The container grows when the line
    /// puts the buttons past its bottom, so they stay inside it and keep their clicks (a view outside
    /// its superview's frame gets no hits). A nil `centerY` is macOS's own place: centered in the
    /// native container. Pure, so `TrafficLightsLineTests` holds it with fixed numbers.
    public nonisolated static func placement(centerY: CGFloat?, buttonHeight: CGFloat, nativeHeight: CGFloat,
                                             scale: CGFloat) -> Placement {
        let s = max(scale, 1)
        let center = ((centerY ?? nativeHeight / 2) * s).rounded() / s
        let height = max(nativeHeight, ((center + buttonHeight / 2) * s).rounded(.up) / s)
        return Placement(containerHeight: height, centerY: center, leadingX: ((center - buttonHeight / 2) * s).rounded() / s)
    }

    /// The line the lights take in `window`: the top row's (``WindowTitlebar/topRowLine(in:look:)``) for the
    /// variants whose line does not come from the lights, nil (macOS's place) otherwise.
    public static func targetCenterY(in window: NSWindow, look: TopRowLineLook = TopRowLineLook.tunable.value) -> CGFloat? {
        guard look != .lights, look != .off else { return nil }
        return WindowTitlebar.topRowLine(in: window, look: look)?.centerY
    }

    /// Moves `window`'s traffic lights onto its top row's line (``targetCenterY(in:look:)``), or back to macOS's place.
    /// The root view's layout runs it, and so does the end of every layout pass of the window: AppKit lays its titlebar
    /// out again on its own (a new window title, an appearance or key change) and puts the lights back at its place, 16 pt
    /// below the window's top, without a layout of the root view. The user's window showed them so, 4 pt above the toolbar
    /// band and the tabs (2026-11-19: "traffic lights not aligned").
    public static func apply(in window: NSWindow) { // perf-hot: 1ms motion-frame
        apply(in: window, centerY: targetCenterY(in: window))
    }

    /// Where `window`'s traffic lights rest on their line, in window coordinates: the frame ``apply(in:)`` gives the three
    /// buttons, from the same numbers (the line, the close button's inset, macOS's spacing), never read back from the
    /// buttons. After a new window title AppKit re-tiles the miniaturize and zoom buttons inside its own run loop callouts
    /// and the owner puts them back only at the next pass; read from the buttons in between, the lights were a 51 x 23 pt
    /// box 4.5 pt above their line, and Home's header laid out on it and kept it (HomeHeaderStaysPutTests). A layout that
    /// follows the lights reads this. Where no owner places them (a window that keeps macOS's place, full screen, right to
    /// left, a window coming back from full screen) it is the buttons' frames (``WindowTitlebar/trafficLightsFrame(in:)``).
    public static func restingFrame(in window: NSWindow) -> CGRect? {
        guard let owner = TrafficLightsOwner.existing(window), !window.styleMask.contains(.fullScreen),
              window.windowTitlebarLayoutDirection == .leftToRight,
              (window as? any TrafficLightsResting)?.restingTrafficLights == nil,
              let close = window.standardWindowButton(.closeButton), close.window === window else {
            return WindowTitlebar.trafficLightsFrame(in: window)
        }
        let native = window.frame.height - window.contentLayoutRect.maxY
        let offsets = owner.offsets(for: window.styleMask)
        guard native > 0, !offsets.isEmpty else { return WindowTitlebar.trafficLightsFrame(in: window) }
        let placement = placement(centerY: targetCenterY(in: window), buttonHeight: close.frame.height, nativeHeight: native,
                                  scale: window.backingScaleFactor)
        let midY = window.frame.height - placement.centerY
        var frame: CGRect?
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHidden, button.window === window,
                  let offset = offsets[type] else { continue }
            let size = button.frame.size
            let rect = CGRect(x: placement.leadingX + offset, y: midY - size.height / 2, width: size.width, height: size.height)
            frame = frame.map { $0.union(rect) } ?? rect
        }
        return frame ?? WindowTitlebar.trafficLightsFrame(in: window)
    }

    /// Moves `window`'s traffic lights onto `centerY` (from the window's top), or back to macOS's place for nil.
    ///
    /// Each button gets its whole place here, from fixed numbers: the line's center, the close button's inset and each
    /// button's distance from the close button in macOS's own tiling (``TrafficLightsOwner/nativeOffsets(for:)``, read
    /// once per window from a window nobody moved). Nothing is read back from the buttons' frames now, so a button AppKit tiled on
    /// its own (it re-tiles the miniaturize and zoom buttons after a new window title, from numbers it took before any
    /// placement of ours) goes back to the same place as the others. Moving the buttons by the close button's shift
    /// left such a button at macOS's place (the user's recording, 2026-11-19: "traffic light shifts around"), and so did
    /// shifting the titlebar view's bounds (fleet step da97baab: AppKit tiles the buttons in window coordinates).
    /// Runs in the root view's layout, at the end of the window's layout pass, and from the window's
    /// ``TrafficLightsOwner`` when AppKit moves a button or resizes their container: at once in AppKit's own call, and
    /// once more just before Core Animation commits the frame. The container grows when the line puts the buttons past
    /// its bottom, so they keep their clicks. Sets a frame only when it changes. Right to left, x stays macOS's.
    public static func apply(in window: NSWindow, centerY: CGFloat?) { // perf-hot: 1ms motion-frame
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), close.window === window,
              let titlebar = close.superview, let container = titlebar.superview, let frameView = container.superview else { return }
        let native = window.frame.height - window.contentLayoutRect.maxY
        guard native > 0 else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { type in window.standardWindowButton(type).map { (type, $0) } }.filter { $0.1.superview === titlebar }
        let owner = TrafficLightsOwner.of(window)
        owner.watch(container: container, buttons: buttons.map(\.1), in: window)
        let offsets = owner.offsets(for: window.styleMask)
        let leftToRight = window.windowTitlebarLayoutDirection == .leftToRight
        let settled = owner.place {
            let placement = placement(centerY: centerY, buttonHeight: close.frame.height, nativeHeight: native,
                                      scale: window.backingScaleFactor)
            let containerFrame = CGRect(x: container.frame.minX,
                                        y: frameView.isFlipped ? 0 : frameView.bounds.maxY - placement.containerHeight,
                                        width: container.frame.width, height: placement.containerHeight)
            var moved = false
            if container.frame != containerFrame { container.frame = containerFrame; moved = true }
            // The close button's left edge and the buttons' center, in window coordinates (bottom-left origin), then in
            // the titlebar view's.
            let anchor = titlebar.convert(CGPoint(x: placement.leadingX, y: window.frame.height - placement.centerY), from: nil)
            let start = close.frame.minX
            for (type, button) in buttons {
                let x = leftToRight ? anchor.x + (offsets[type] ?? button.frame.minX - start) : button.frame.minX
                let origin = CGPoint(x: x, y: anchor.y - button.frame.height / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin); moved = true }
            }
            return !moved
        }
        // Where this placement left them, for the owner's next "AppKit moved them" (only a placement that settled).
        owner.rest = settled ? TrafficLightsOwner.Rest(in: window) : nil
    }
}

/// The one owner of a window's traffic lights' place (the user, 2026-11-19: "traffic light shifts around which is very
/// bad; fix from first principles, fix root cause"). AppKit tiles its titlebar again on its own (a new window title, an
/// appearance or key change, its titlebar's layout) with no layout of any app view, and puts the buttons back at its
/// place. The owner hears each button's and the container's frame change in the call that made it and places them
/// again at once (``TrafficLightsLine/apply(in:centerY:)``), then once more just before Core Animation commits the
/// frame, after AppKit's display cycle, for a move made after ours in the same call (its tiling sets the buttons one
/// by one, from numbers it took first). A move AppKit makes inside its own before-waiting callouts (its display cycle,
/// the commit) gets that last pass only in the next run loop pass; the placement at once covers it.
@MainActor
public final class TrafficLightsOwner {
    private weak var window: NSWindow?
    /// Each view heard (the buttons and their container) with its observation. AppKit makes new ones on a style or
    /// full-screen change: the new ones are heard at the next placement, and a view that left the window drops out then
    /// with its observation (each removes itself when released, and all go with the owner at the window's end).
    private struct Watched {
        weak var view: NSView?
        let observation: MainActorObservation
    }
    private var watched: [Watched] = []
    /// True while the lights are placed: their own frame changes are not AppKit's.
    private var isPlacing = false
    /// The placements run (``place(_:)``) since the owner was made: a window pass that moved nothing runs none (tests).
    public private(set) var placements = 0
    /// A placement before Core Animation's next commit is asked for.
    private var commitPassPending = false
    /// Core Animation commits at order 2,000,000 of the main run loop's before-waiting stage, after AppKit's display
    /// cycle: the last moment a frame can still change what the screen shows.
    static let commitPassOrder: CFIndex = 1_999_999

    private static var key: UInt8 = 0
    /// macOS's own spacing of the buttons for this window's style mask (``nativeOffsets(for:)``), read once per mask.
    private var spacing: (mask: UInt, offsets: [NSWindow.ButtonType: CGFloat])?

    /// The lights and their container as seen from the window's top-left corner, with what the placement reads from the
    /// window (its titlebar's height, its scale, its style). A live resize of the window moves the container with the
    /// window's top edge and widens it each step, so AppKit's frame change arrives with every light where the last
    /// placement put it; placing them again there read the top row's line (every density token) for nothing.
    struct Rest: Equatable {
        var nativeHeight: CGFloat
        var scale: CGFloat
        var styleMask: UInt
        var containerHeight: CGFloat
        var containerTopGap: CGFloat
        var buttons: [CGPoint]

        init?(in window: NSWindow) {
            guard let close = window.standardWindowButton(.closeButton), close.window === window,
                  let titlebar = close.superview, let container = titlebar.superview, let frameView = container.superview else { return nil }
            let height = window.frame.height
            nativeHeight = height - window.contentLayoutRect.maxY
            scale = window.backingScaleFactor
            styleMask = window.styleMask.rawValue
            containerHeight = container.frame.height
            containerTopGap = frameView.isFlipped ? container.frame.minY : frameView.bounds.maxY - container.frame.maxY
            buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGPoint? in
                guard let button = window.standardWindowButton(type), button.superview === titlebar else { return nil }
                let frame = button.convert(button.bounds, to: nil)
                return CGPoint(x: frame.minX, y: height - frame.maxY) // from the window's top: a resize moves neither
            }
        }
    }
    /// Where the last settled placement left the lights (``TrafficLightsLine/apply(in:centerY:)``); nil before one, or
    /// after a placement AppKit fought for all three runs. A new line reaches the lights through the root view's layout,
    /// which places them unconditionally; this only spares the frame changes that moved nothing of ours.
    var rest: Rest?
    /// The lights and their container are where the last placement left them.
    private func isAtRest(_ window: NSWindow) -> Bool {
        guard let rest else { return false }
        return Rest(in: window) == rest
    }

    /// The owner of `window`'s lights, made on first use.
    public static func of(_ window: NSWindow) -> TrafficLightsOwner {
        if let owner = objc_getAssociatedObject(window, &key) as? TrafficLightsOwner { return owner }
        let owner = TrafficLightsOwner(window: window)
        objc_setAssociatedObject(window, &key, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return owner
    }

    /// The owner of `window`'s lights when something placed them; nil otherwise (it makes none).
    static func existing(_ window: NSWindow) -> TrafficLightsOwner? {
        objc_getAssociatedObject(window, &key) as? TrafficLightsOwner
    }

    private init(window: NSWindow) { self.window = window }

    /// ``nativeOffsets(for:)`` for `styleMask`, read once per tiling mask for this window: only a change of the bits
    /// that change macOS's tiling reads it again (full screen does not).
    func offsets(for styleMask: NSWindow.StyleMask) -> [NSWindow.ButtonType: CGFloat] {
        let mask = Self.tilingMask(styleMask)
        if let spacing, spacing.mask == mask.rawValue { return spacing.offsets }
        let offsets = Self.nativeOffsets(for: mask)
        spacing = (mask.rawValue, offsets)
        return offsets
    }

    /// The bits of `styleMask` that decide macOS's tiling of the buttons, with every button there.
    static func tilingMask(_ styleMask: NSWindow.StyleMask) -> NSWindow.StyleMask {
        styleMask.intersection([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            .union([.titled, .closable, .miniaturizable, .resizable])
    }

    /// How far each button's left edge sits from the close button's in macOS's own tiling for `styleMask`: read from a
    /// window of that style that nothing moved, never from a window whose buttons were placed (a snapshot taken while
    /// AppKit had tiled only some of them would keep the wrong spacing). Empty when that window has no such tiling.
    public static func nativeOffsets(for styleMask: NSWindow.StyleMask) -> [NSWindow.ButtonType: CGFloat] {
        let mask = tilingMask(styleMask)
        let bare = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: mask, backing: .buffered, defer: true)
        bare.isReleasedWhenClosed = false
        var out: [NSWindow.ButtonType: CGFloat] = [:]
        if let close = bare.standardWindowButton(.closeButton) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = bare.standardWindowButton(type), button.superview === close.superview else { continue }
                out[type] = button.frame.minX - close.frame.minX
            }
        }
        // AppKit always tiles close, miniaturize, zoom left to right, each past the last; anything else is no tiling, and
        // the placement keeps each button's own distance from the close button then.
        let valid = out[.closeButton] == 0 && (out[.miniaturizeButton] ?? 0) > 0 && (out[.zoomButton] ?? 0) > (out[.miniaturizeButton] ?? 0)
        return valid ? out : [:]
    }

    /// Runs `body` as the lights' placement until a run finds every frame already in place (`body` returns true when it
    /// changed nothing), at most three runs: a move AppKit makes inside it (its tiling, run by one of our frame changes)
    /// is undone by the next run, which reads nothing from the frames AppKit set.
    /// Returns whether a run found every frame in place (false when AppKit fought all three, or a placement was running).
    @discardableResult
    func place(_ body: () -> Bool) -> Bool {
        guard !isPlacing else { return false }
        isPlacing = true
        placements += 1
        defer { isPlacing = false }
        for _ in 0..<3 where body() { return true }
        return false
    }

    /// Hears `container` and `buttons` (once per view), and lets go of views that left `window`.
    func watch(container: NSView, buttons: [NSView], in window: NSWindow) {
        watched.removeAll { $0.view == nil || $0.view?.window !== window }
        for view in [container] + buttons where !watched.contains(where: { $0.view === view }) {
            view.postsFrameChangedNotifications = true
            // At once: in AppKit's own call that changed it, before the frame draws (a queued delivery is a frame late).
            watched.append(Watched(view: view, observation: MainActorObservation(NSView.frameDidChangeNotification, object: view,
                                                                                 atOnce: true, read: { _ in () }) { [weak self] _ in
                self?.appKitMovedThem()
            }))
        }
    }

    /// AppKit moved a button or resized their container: back onto the line in the same call, and once more before the
    /// frame commits. A change that left every light where the last placement put them, seen from the window's top
    /// (``Rest``: a live resize step), places nothing; the commit pass still looks, for a move AppKit makes with no frame
    /// change heard (its titlebar view's bounds).
    private func appKitMovedThem() {
        guard !isPlacing, let window else { return }
        if !isAtRest(window) { TrafficLightsLine.apply(in: window) }
        guard !commitPassPending else { return }
        commitPassPending = true
        MainRunLoopObserver.once(activities: .beforeWaiting, order: Self.commitPassOrder) { [weak self] in
            guard let self else { return }
            commitPassPending = false
            if let window = self.window, !isAtRest(window) { TrafficLightsLine.apply(in: window) }
        }
    }
}
