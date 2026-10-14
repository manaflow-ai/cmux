// From MessagesLab bd65bbf appkit-native/Sources/FrameTick.swift (not vendored: it is a
// Host.swift helper). Unchanged except this header; IdleAfterFirstFrame from 7924f00 (0b58d56).
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

/// Runs work once, when the main run loop first goes idle after the view's window has shown its
/// first frame: no fixed delay (the launch warm-up, ChatController.install).
///
/// 1. A beforeWaiting observer ordered after Core Animation's commit observer sees the run-loop
///    pass whose commit holds the window's first visible content (the window visible and not
///    occluded; while it is occluded, the occlusion notification re-arms this step).
/// 2. The next display-link frame of the view's screen: that commit is on screen.
/// 3. The next time the run loop goes idle (beforeWaiting: no source, timer or event waits), the
///    work runs in the default mode, from a block of the next pass (not inside the observer).
final class IdleAfterFirstFrame: NSObject {
    private weak var view: NSView?
    private var work: (() -> Void)?
    private var observer: CFRunLoopObserver?
    private var link: CADisplayLink?
    private var occlusion: NSObjectProtocol?

    init(view: NSView, work: @escaping () -> Void) { self.view = view; self.work = work }

    func start() { onIdle { [weak self] in self?.firstFrameCommitted() } }

    /// One beforeWaiting pass of the main run loop, after Core Animation's commit (order max).
    private func onIdle(_ f: @escaping () -> Void) {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { [weak self] _, _ in
            self?.observer = nil
            f()
        }
        observer = o
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .defaultMode)
    }

    private func firstFrameCommitted() {
        guard let view, let window = view.window else { work = nil; return }
        guard window.isVisible, window.occlusionState.contains(.visible) else {
            // Not on screen yet: wait for the window server to report it visible, then step 1 again.
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, let o = self.occlusion, window.occlusionState.contains(.visible) else { return }
                NotificationCenter.default.removeObserver(o); self.occlusion = nil
                self.start()
            }
            return
        }
        let l = view.displayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .default)
        link = l
    }

    @objc private func frame(_ l: CADisplayLink) {
        l.invalidate(); link = nil
        onIdle { [weak self] in
            // The work may run a nested event-tracking loop (a menu): not from inside the observer.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                let w = self?.work; self?.work = nil; w?()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
