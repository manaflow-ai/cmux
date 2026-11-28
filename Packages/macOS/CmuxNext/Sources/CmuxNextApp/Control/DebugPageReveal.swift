#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

/// `debug.page_reveal {action}` (DEBUG builds): takes the main window off the screen and back without activating the
/// app, as a switch to another app and back does, and samples the window's remote page layers (`CALayerHost`, a
/// Chromium page's compositor output, in tree or layer hosted) every 4 ms from the first action to the end.
///
/// Actions: `hide` (`NSApp.hide`), `show` (`NSApp.unhideWithoutActivation`), `cover` (an opaque window of this app
/// ordered over the main window, so it is occluded while the app keeps its windows) and `uncover`, `samples` (the
/// sampling so far and its summary; it stops the sampler), `front` (the main window above every other app's
/// windows, `orderFrontRegardless`, still without activating: a host whose screen another app's window fills). Every reply carries `occluded` (the window's occlusion
/// state lacks `.visible`) and `hidden` (`NSApp.isHidden`).
///
/// The summary, `reveal`: the remote layers' context ids when the window left the screen, when it was visible again,
/// and `replaced_ms`, how long after it was visible again those ids were replaced (null: never). A page whose
/// compositor went away while hidden has a dead context in its `CALayerHost`, so the page shows only its background
/// until the new compositor's first frame swaps a new id in: `replaced_ms` is that blank time on screen. A page that
/// kept its compositor keeps its ids (`replaced_ms` null).
@MainActor
enum DebugPageReveal {
    private static var sampler: Sampler?
    private static var cover: NSWindow?

    static func run(_ params: [String: JSONValue]) -> JSONValue {
        let action = params["action"]?.stringValue ?? "samples"
        let app = NSApplication.shared
        guard let window = sampler?.window ?? mainWindow() else { return .object(["error": .string("no main window")]) }
        switch action {
        case "hide", "cover":
            let sampler = Sampler(window: window)
            Self.sampler?.stop()
            Self.sampler = sampler
            sampler.mark(action)
            if action == "hide" {
                app.hide(nil)
            } else {
                let made = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20), styleMask: .borderless,
                                    backing: .buffered, defer: false)
                made.isReleasedWhenClosed = false
                made.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 1)
                made.isOpaque = true
                made.hasShadow = false
                made.ignoresMouseEvents = true
                made.level = window.level
                made.animationBehavior = .none
                made.order(.above, relativeTo: window.windowNumber)
                cover = made
            }
        case "show":
            sampler?.mark(action)
            app.unhideWithoutActivation()
        case "uncover":
            sampler?.mark(action)
            cover?.orderOut(nil)
            cover = nil
        case "front":
            window.orderFrontRegardless()
        case "samples":
            let result = sampler?.report() ?? .null
            sampler?.stop()
            sampler = nil
            return .object(["samples": result])
        default:
            return .object(["error": .string("unknown action \(action)")])
        }
        sampler?.sample()
        return .object([
            "action": .string(action),
            "occluded": .bool(!window.occlusionState.contains(.visible)),
            "hidden": .bool(app.isHidden),
        ])
    }

    private static func mainWindow() -> NSWindow? {
        let app = NSApplication.shared
        return app.mainWindow ?? app.windows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
    }

    /// Every remote layer (`CALayerHost`, any size: Chromium's has no bounds of its own) in the window's layer tree,
    /// by context id; 0 ids are left out.
    static func remoteContextIDs(in window: NSWindow) -> [UInt32] {
        guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return [] }
        var ids: [UInt32] = []
        var stack: [CALayer] = [root]
        while let layer = stack.popLast() {
            if NSStringFromClass(type(of: layer)) == "CALayerHost",
               let id = (layer.value(forKey: "contextId") as? NSNumber)?.uint32Value, id != 0 {
                ids.append(id)
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return ids.sorted()
    }

    @MainActor
    private final class Sampler {
        struct Sample {
            var ms: Double
            var visible: Bool
            var hidden: Bool
            var ids: [UInt32]
        }

        let window: NSWindow
        private let start = ContinuousClock.now
        private var timer: Timer?
        private var samples: [Sample] = []
        private var marks: [(name: String, ms: Double)] = []
        private var ticks = 0

        init(window: NSWindow) {
            self.window = window
            let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
                MainActor.assumeIsolated { DebugPageReveal.sampler?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            sample()
        }

        private var now: Double { Double((ContinuousClock.now - start) / .microseconds(1)) / 1000 }

        func mark(_ name: String) {
            marks.append((name, now))
        }

        /// One sample, kept when the window's visibility or its remote layers changed.
        func sample() {
            ticks += 1
            let next = Sample(ms: now, visible: window.occlusionState.contains(.visible),
                              hidden: NSApplication.shared.isHidden, ids: DebugPageReveal.remoteContextIDs(in: window))
            if let last = samples.last, last.visible == next.visible, last.hidden == next.hidden, last.ids == next.ids {
                return
            }
            samples.append(next)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func report() -> JSONValue {
            func ids(_ list: [UInt32]) -> JSONValue { .array(list.map { .number(Double($0)) }) }
            // The ids on screen before the window left, and the first visible sample after the last show.
            let leftAt = marks.first { $0.name == "hide" || $0.name == "cover" }?.ms ?? 0
            let shownAt = marks.last { $0.name == "show" || $0.name == "uncover" }?.ms
            let before = samples.last { $0.ms <= leftAt && $0.visible }?.ids ?? samples.first?.ids ?? []
            var reveal: [String: JSONValue] = ["ids_before": ids(before)]
            if let shownAt, let visible = samples.first(where: { $0.ms >= shownAt && $0.visible }) {
                let replaced = samples.first { $0.ms >= visible.ms && $0.ids != visible.ids }
                reveal["visible_ms_after_show"] = .number(visible.ms - shownAt)
                reveal["ids_visible"] = ids(visible.ids)
                reveal["ids_last"] = ids(samples.last?.ids ?? [])
                reveal["replaced_ms"] = replaced.map { .number($0.ms - visible.ms) } ?? .null
                reveal["kept_ids"] = .bool(!before.isEmpty && Set(before).isSubset(of: Set(samples.last?.ids ?? [])))
            }
            return .object([
                "ticks": .number(Double(ticks)),
                "marks": .array(marks.map { .object(["name": .string($0.name), "ms": .number($0.ms)]) }),
                "changes": .array(samples.map { sample in
                    .object(["ms": .number(sample.ms), "visible": .bool(sample.visible), "hidden": .bool(sample.hidden),
                             "ids": ids(sample.ids)])
                }),
                "reveal": .object(reveal),
            ])
        }
    }
}
#endif
