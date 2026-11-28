// From MessagesLab bd65bbf appkit-native/Sources/FrameTick.swift (not vendored: it is a
// Host.swift helper). Unchanged except this header.
import AppKit

/// Runs work at the start of the next display frame of a view's screen: a display
/// link that is paused while nothing waits (no polling).
///
/// Users: page landings (Pager) and the engine jobs a keystroke went ahead of
/// (Host.dispatch). A landing that arrived from the loader queue late in a frame
/// committed after the frame's deadline (a 2 ms commit, still a dropped frame in a
/// knob drag over the 1M store); at the frame's start it has the whole frame.
final class FrameTick: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var work: [() -> Void] = []

    init(view: NSView) { self.view = view }

    func next(_ f: @escaping () -> Void) {
        work.append(f)
        if let link { link.isPaused = false; return }
        guard let view else { f(); work.removeAll(); return }
        let l = view.displayLink(target: self, selector: #selector(fire(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func fire(_ l: CADisplayLink) {
        let w = work
        work.removeAll(keepingCapacity: true)
        l.isPaused = work.isEmpty
        for f in w { f() }
        if !work.isEmpty { l.isPaused = false }
    }
}
