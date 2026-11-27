#if DEBUG && os(iOS)
import CmuxMobileSupport
import Darwin
import QuartzCore
import UIKit

/// `-cmux-mobile-kbd-inject slide|tti` (with `-cmux-mobile-kbd-pin-trace`):
/// the keyboard bench's second input, fired from inside the app on the
/// trace's clock instead of by XCUITest, whose runner waits for the app to go
/// idle before every synthesized event (0.8-1.4 s after the keyboard stops in
/// KeyboardMotionBenchUITests' time-to-interactive rows).
///
/// - `slide`: at willShow/willHide + 100, 200, 300 ms (and + 900 ms, after the
///   keyboard settled: the control that says a touch fired this way lands),
///   in turn, one per keyboard move: a touch where the user sees the target,
///   the composer field on a show, the content behind it on a hide (a 30 pt
///   drag). Leo, 2026-11-21: "the thing drops / the display isn't immediately
///   motherf***ing responsive."
/// - `tti`: on a show, a key into the first responder right after willShow
///   (`off=will`: does the field take input while the keyboard is still
///   coming), then on every move a key (show) or the same drag (hide) on the
///   first frame the keyboard is drawn at the notified end after it was drawn
///   off it (`off=stop`). The keyboard's placeholder has no presentation layer
///   until the move's animation is committed, so a frame between willShow and
///   that commit reads the placeholder's model frame, already at the end: the
///   first bench took that frame for the stop in 19 of 20 terminal and Chief
///   moves (1 ms after willShow; the keyboard was drawn at its end 390 ms
///   later on every surface).
///
/// Each one writes `ev=inject` with when it was due (`due=`), how late the
/// main thread ran it (`lag=` ms), what UIKit's hit-test picked at the drawn
/// point (`hit=`), whether that is the target (`ok=`), whether the touch went
/// through `UIApplication.sendEvent` (`sent=`), and later `ev=injectDone`
/// with the ms to the app taking it (the touch reaching the window's touch
/// marker, the content tracking the drag, or the edit landing).
///
/// The touch is built as KIF and WebKit's HIDEventGenerator build one in
/// process (a UITouch with a digitizer IOHIDEvent, sent through the touches
/// event); every private selector and symbol is looked up first, and a
/// missing one writes `sent=0` instead of sending.
@MainActor
final class KeyboardInputInjector {
    static let flag = "-cmux-mobile-kbd-inject"

    enum Mode: String { case slide, tti }

    static func modeIfRequested() -> Mode? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Mode(rawValue: args[i + 1])
    }

    let mode: Mode
    private let start: CFTimeInterval
    private let write: (String) -> Void
    private let window: () -> UIWindow?

    init(mode: Mode, start: CFTimeInterval, window: @escaping () -> UIWindow?, write: @escaping (String) -> Void) {
        self.mode = mode
        self.start = start
        self.window = window
        self.write = write
    }

    static let slideOffsets: [Double] = [0.1, 0.2, 0.3, 0.9]
    private var shown = false
    private var moves = 0
    /// Moves per direction, so each direction takes every offset in turn.
    private var shows = 0
    private var hides = 0
    /// tti: the move whose keyboard end is awaited (direction, end top, since).
    private var awaiting: (show: Bool, endY: CGFloat, since: CFTimeInterval, moved: Bool)?
    /// The injection the touch marker or the edit is awaited for.
    private var pending: Pending?

    private struct Pending {
        var id: Int
        var show: Bool
        var fired: CFTimeInterval
        var target: UIView?
        var key: Bool
        var touched = false
    }

    private func now() -> CFTimeInterval { CACurrentMediaTime() - start }

    // MARK: - Inputs from KeyboardPinTrace

    func keyboard(willShow: Bool, endY: CGFloat) {
        guard willShow != shown else { return }
        shown = willShow
        moves += 1
        let move = moves
        let t = now()
        switch mode {
        case .slide:
            if willShow { shows += 1 } else { hides += 1 }
            let offset = Self.slideOffsets[((willShow ? shows : hides) - 1) % Self.slideOffsets.count]
            let due = t + offset
            let timer = Timer(timeInterval: offset, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire(move: move, show: willShow, due: due, offset: offset) }
            }
            RunLoop.main.add(timer, forMode: .common)
        case .tti:
            awaiting = (willShow, endY, t, false)
            // After every willShow observer (the composers' docks) has run.
            if willShow {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.fire(move: move, show: true, due: t, offset: 0) }
                }
            }
        }
    }

    /// Every display frame: the keyboard's top as drawn (nil: none on screen).
    func frame(keyboardTop: CGFloat?, windowBottom: CGFloat) {
        guard mode == .tti, let wait = awaiting else { return }
        let top = keyboardTop ?? windowBottom
        let end = wait.show ? wait.endY : max(wait.endY, windowBottom)
        guard wait.moved, abs(top - end) <= 0.5 || (!wait.show && keyboardTop == nil) else {
            if abs(top - end) > 0.5 { awaiting?.moved = true }
            if now() - wait.since > 3 { awaiting = nil; write(String(format: "t=%.4f ev=inject mode=tti miss=noend", now())) }
            return
        }
        awaiting = nil
        let t = now()
        write(String(format: "t=%.4f ev=kbStop dir=%@", t, wait.show ? "show" : "hide"))
        fire(move: moves, show: wait.show, due: t, offset: -1)
    }

    /// The window's touch marker saw a touch begin on `view`.
    func touchBegan(view: UIView?) {
        guard let p = pending, !p.key, !p.touched else { return }
        let t = now()
        let onTarget = view.map { v in p.target.map { v.isDescendant(of: $0) } ?? false } ?? false
        write(String(format: "t=%.4f ev=injectDone id=%d got=touch view=%@ tgt=%d ms=%.2f", t, p.id,
                     view.map { Self.name($0) } ?? "-", onTarget ? 1 : 0, (t - p.fired) * 1000))
        // A hide's drag goes on to its own `got=drag` line.
        if p.show { pending = nil } else { pending?.touched = true }
    }

    /// An edit landed (a text view, a text field or the terminal took a key).
    func keyAccepted() {
        guard let p = pending, p.key else { return }
        let t = now()
        write(String(format: "t=%.4f ev=injectDone id=%d got=key ms=%.2f", t, p.id, (t - p.fired) * 1000))
        pending = nil
    }

    // MARK: - Firing

    private var fired = 0

    private func fire(move: Int, show: Bool, due: CFTimeInterval, offset: Double) {
        guard let window = window() else { return }
        fired += 1
        let id = fired
        let t = now()
        let lag = (t - due) * 1000
        let dir = show ? "show" : "hide"
        let off = offset < 0 ? "stop" : mode == .tti ? "will" : String(format: "%.0f", offset * 1000)
        if mode == .tti, show {
            // A key into whatever has the keyboard: the keyboard's own keys
            // never pass the app's hit-test, so the question is how soon the
            // app takes the edit.
            let responder = UIResponder.cmuxCurrentFirstResponder()
            let input = responder as? UIKeyInput
            let name = responder.map { Self.name($0) } ?? "-"
            write(String(format: "t=%.4f ev=inject id=%d mode=%@ dir=%@ off=%@ due=%.4f lag=%.2f key=%@ ok=%d sent=%d",
                         t, id, mode.rawValue, dir, off, due, lag, name, input == nil ? 0 : 1, input == nil ? 0 : 1))
            guard let responder, let input else { return }
            pending = Pending(id: id, show: true, fired: CACurrentMediaTime() - start, target: nil, key: true)
            input.insertText("a")
            // Leave the text as it was, after the edit has been read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { (responder as? UIKeyInput)?.deleteBackward() }
            }
            return
        }
        // Where the user sees the target: the field on a show, the content on a hide.
        let field = KeyboardPinTrace.composerField(in: window)
        // No field to touch yet (the chat's collapsed capsule builds its field
        // about 140 ms after willShow): a touch at a guessed point lands on the
        // transcript, whose rows open a file or the diff and whose end-editing
        // tap takes the keyboard down, and every later step of the run is lost.
        if show, field == nil {
            write(String(format: "t=%.4f ev=injectSkip id=%d mode=%@ dir=%@ off=%@ due=%.4f lag=%.2f why=nofield",
                         t, id, mode.rawValue, dir, off, due, lag))
            return
        }
        var target: UIView?
        var point = CGPoint(x: window.bounds.midX, y: window.bounds.height * 0.4)
        if show, let field {
            target = field
            let drawn = MobileKeyboardProbe().onScreen(field, in: window)
            point = CGPoint(x: drawn.midX, y: drawn.midY)
        } else if !show {
            // The content the user sees: what is drawn behind the field, else
            // (the composer folded away) what the window shows there.
            let content = field.flatMap { KeyboardPinTrace.content(behind: $0, in: window) }
                ?? window.hitTest(point, with: nil).flatMap(Self.scroll(holding:))
            if let content {
                target = content
                let drawn = MobileKeyboardProbe().onScreen(content, in: window)
                point = CGPoint(x: drawn.midX, y: drawn.minY + drawn.height * 0.4)
            }
        }
        let hit = window.hitTest(point, with: nil)
        // A hide's target is the content the finger lands on: the tallest
        // scroll view behind the field is not always it (the terminal's grid
        // sits in its own scroll view inside a taller hosting one).
        if !show, let hit, !(target.map { hit.isDescendant(of: $0) } ?? false), let under = Self.scroll(holding: hit) {
            target = under
        }
        let ok = hit.map { h in target.map { h.isDescendant(of: $0) } ?? false } ?? false
        let touch = SyntheticTouch(window: window, point: point, view: hit)
        write(String(format: "t=%.4f ev=inject id=%d mode=%@ dir=%@ off=%@ due=%.4f lag=%.2f x=%.1f y=%.1f hit=%@ tgt=%@ ok=%d sent=%d",
                     t, id, mode.rawValue, dir, off, due, lag, point.x, point.y,
                     hit.map { Self.name($0) } ?? "-", target.map { Self.name($0) } ?? "-", ok ? 1 : 0, touch == nil ? 0 : 1)
              + (touch == nil ? " missing=" + SyntheticTouch.Private.missing : ""))
        guard let touch else { return }
        pending = Pending(id: id, show: show, fired: CACurrentMediaTime() - start, target: target, key: false)
        touch.send(.began)
        let scroll = target as? UIScrollView
        if show {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { touch.send(.ended) } }
            // After the tap ends: does the field still hold the keyboard (a
            // wrong target, a button of the stack, would take it or end editing).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak target] in MainActor.assumeIsolated {
                guard let self else { return }
                self.write(String(format: "t=%.4f ev=injectFocus id=%d fr=%d", self.now(), id, target?.isFirstResponder == true ? 1 : 0))
            } }
        } else {
            // A short drag down the content: a scroll, as the bench's own second input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { MainActor.assumeIsolated { touch.move(by: 15); touch.send(.moved) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in MainActor.assumeIsolated {
                touch.move(by: 15)
                touch.send(.moved)
                guard let self else { return }
                let t = self.now()
                // Taken: a scroll or a pan under the finger is dragging (the
                // terminal's TUI pans with no scroll view).
                let taken = (scroll?.isDragging ?? false) || hit.map(Self.dragging(under:)) ?? false
                self.write(String(format: "t=%.4f ev=injectDone id=%d got=drag trk=%d ms=%.2f", t, id,
                                  taken ? 1 : 0, (t - (self.pending?.fired ?? t)) * 1000))
                if self.pending?.id == id { self.pending = nil }
            } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { touch.send(.ended) } }
        }
    }

    /// The nearest scroll view (not a text view) holding `view`.
    static func scroll(holding view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let v = current {
            if let s = v as? UIScrollView, !(s is UITextView) { return s }
            current = v.superview
        }
        return nil
    }

    /// A scroll view dragging or a pan recognizer began, from `view` up.
    static func dragging(under view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if let s = v as? UIScrollView, s.isDragging { return true }
            if v.gestureRecognizers?.contains(where: { $0 is UIPanGestureRecognizer && ($0.state == .began || $0.state == .changed) }) == true {
                return true
            }
            current = v.superview
        }
        return false
    }

    static func name(_ object: AnyObject) -> String {
        if let view = object as? UIView, let id = view.accessibilityIdentifier, !id.isEmpty { return id.replacingOccurrences(of: " ", with: "_") }
        return String(describing: type(of: object)).replacingOccurrences(of: " ", with: "_")
    }
}

@MainActor
extension UIResponder {
    private static weak var cmuxFound: UIResponder?

    @objc private func cmuxCaptureFirstResponder(_ sender: Any?) {
        UIResponder.cmuxFound = self
    }

    /// The first responder, through the responder chain's nil-targeted action.
    static func cmuxCurrentFirstResponder() -> UIResponder? {
        cmuxFound = nil
        UIApplication.shared.sendAction(#selector(cmuxCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return cmuxFound
    }
}

/// One finger, sent through `UIApplication.sendEvent` from inside the app.
@MainActor
final class SyntheticTouch {
    private let touch: UITouch
    private let window: UIWindow
    private var point: CGPoint

    init?(window: UIWindow, point: CGPoint, view: UIView?) {
        guard Private.ready else { return nil }
        self.window = window
        self.point = point
        touch = UITouch()
        Private.callObject(touch, "setWindow:", window)
        Private.callInt(touch, "setTapCount:", 1)
        Private.callPoint(touch, "_setLocationInWindow:resetPrevious:", point, true)
        if let view { Private.callObject(touch, "setView:", view) }
        Private.callInt(touch, "setPhase:", UITouch.Phase.began.rawValue)
        // Optional (KIF calls each only when UITouch has it): a missing one is a no-op.
        Private.callBool(touch, "_setIsFirstTouchForView:", true)
        Private.callBool(touch, "setIsTap:", true)
        if let view { Private.callObject(touch, "setGestureView:", view) }
    }

    func move(by dy: CGFloat) {
        point.y += dy
        Private.callPoint(touch, "_setLocationInWindow:resetPrevious:", point, false)
    }

    func send(_ phase: UITouch.Phase) {
        Private.callInt(touch, "setPhase:", phase.rawValue)
        Private.callDouble(touch, "setTimestamp:", ProcessInfo.processInfo.systemUptime)
        guard let hid = Private.hidEvent(point: point, phase: phase) else { return }
        Private.callObject(touch, Private.touchHIDSetter, hid)
        let app = UIApplication.shared
        guard let event = Private.callReturningObject(app, "_touchesEvent") as? UIEvent else { return }
        Private.callVoid(event, "_clearTouches")
        Private.callObject(event, "_setHIDEvent:", hid)
        Private.callObjectBool(event, "_addTouch:forDelayedDelivery:", touch, false)
        app.sendEvent(event)
    }

    /// The private selectors and IOKit symbols, each looked up before use.
    @MainActor
    enum Private {
        static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        /// IOKit is not always loaded in an app that never links it: dlsym
        /// from the default handle then finds no IOHIDEvent symbol.
        static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(rtldDefault, name) ?? iokit.flatMap { dlsym($0, name) }
        }

        typealias CreateHand = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                                               Double, Double, Double, Double, Double, UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double,
                                                 Double, Double, Double, Double, Double, UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, CFIndex) -> Void
        typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void

        static let createHand = symbol("IOHIDEventCreateDigitizerEvent").map { unsafeBitCast($0, to: CreateHand.self) }
        static let createFinger = symbol("IOHIDEventCreateDigitizerFingerEventWithQuality").map { unsafeBitCast($0, to: CreateFinger.self) }
        static let setInteger = symbol("IOHIDEventSetIntegerValue").map { unsafeBitCast($0, to: SetInteger.self) }
        static let append = symbol("IOHIDEventAppendEvent").map { unsafeBitCast($0, to: Append.self) }

        static let touchSelectors = ["setWindow:", "setTapCount:", "_setLocationInWindow:resetPrevious:", "setView:", "setPhase:",
                                     "setTimestamp:"]
        static let eventSelectors = ["_clearTouches", "_setHIDEvent:", "_addTouch:forDelayedDelivery:"]
        /// UITouch's HID event setter, by either spelling.
        static let touchHIDSetter = ["_setHidEvent:", "_setHIDEvent:"]
            .first { UITouch.instancesRespond(to: NSSelectorFromString($0)) } ?? "_setHidEvent:"

        /// What a send needs and this OS lacks, comma-separated ("" when ready).
        static let missing: String = {
            var gone: [String] = []
            if createHand == nil { gone.append("IOHIDEventCreateDigitizerEvent") }
            if createFinger == nil { gone.append("IOHIDEventCreateDigitizerFingerEventWithQuality") }
            if setInteger == nil { gone.append("IOHIDEventSetIntegerValue") }
            if append == nil { gone.append("IOHIDEventAppendEvent") }
            gone += (touchSelectors + [touchHIDSetter]).filter { !UITouch.instancesRespond(to: NSSelectorFromString($0)) }.map { "UITouch." + $0 }
            if let event = callReturningObject(UIApplication.shared, "_touchesEvent") as? NSObject {
                gone += eventSelectors.filter { !event.responds(to: NSSelectorFromString($0)) }.map { "UITouchesEvent." + $0 }
            } else {
                gone.append("UIApplication._touchesEvent")
            }
            return gone.joined(separator: ",")
        }()

        static let ready: Bool = missing.isEmpty

        // IOHIDEventField: (kIOHIDEventTypeDigitizer 11 << 16) | 25.
        static let fieldDisplayIntegrated: UInt32 = (11 << 16) | 25

        static func hidEvent(point: CGPoint, phase: UITouch.Phase) -> AnyObject? {
            guard let createHand, let createFinger, let setInteger, let append else { return nil }
            let time = mach_absolute_time()
            let touching: UInt8 = (phase == .ended || phase == .cancelled) ? 0 : 1
            // Range | Touch on a change of contact, Position on a move.
            let mask: UInt32 = phase == .moved ? (1 << 2) : (1 << 0 | 1 << 1)
            guard let hand = createHand(kCFAllocatorDefault, time, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, touching, touching, 0) else { return nil }
            setInteger(hand, fieldDisplayIntegrated, 1)
            if let finger = createFinger(kCFAllocatorDefault, time, 1, 2, mask, Double(point.x), Double(point.y), 0, 0, 0,
                                         5, 5, 1, 1, 1, touching, touching, 0) {
                setInteger(finger, fieldDisplayIntegrated, 1)
                append(hand, finger, 0)
                Unmanaged<AnyObject>.fromOpaque(finger).release()
            }
            return Unmanaged<AnyObject>.fromOpaque(hand).takeRetainedValue()
        }

        private static func imp(_ object: AnyObject, _ name: String) -> (Selector, IMP)? {
            let sel = NSSelectorFromString(name)
            guard let cls = object_getClass(object), let method = class_getInstanceMethod(cls, sel) else { return nil }
            return (sel, method_getImplementation(method))
        }

        static func callVoid(_ o: AnyObject, _ name: String) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector) -> Void).self)(o, sel)
        }

        static func callReturningObject(_ o: AnyObject, _ name: String) -> AnyObject? {
            guard let (sel, f) = imp(o, name) else { return nil }
            return unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?).self)(o, sel)?.takeUnretainedValue()
        }

        static func callObject(_ o: AnyObject, _ name: String, _ arg: AnyObject) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Void).self)(o, sel, arg)
        }

        static func callObjectBool(_ o: AnyObject, _ name: String, _ arg: AnyObject, _ flag: Bool) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, AnyObject, ObjCBool) -> Void).self)(o, sel, arg, ObjCBool(flag))
        }

        static func callInt(_ o: AnyObject, _ name: String, _ arg: Int) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, Int) -> Void).self)(o, sel, arg)
        }

        static func callBool(_ o: AnyObject, _ name: String, _ arg: Bool) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, ObjCBool) -> Void).self)(o, sel, ObjCBool(arg))
        }

        static func callDouble(_ o: AnyObject, _ name: String, _ arg: Double) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, Double) -> Void).self)(o, sel, arg)
        }

        static func callPoint(_ o: AnyObject, _ name: String, _ point: CGPoint, _ flag: Bool) {
            guard let (sel, f) = imp(o, name) else { return }
            unsafeBitCast(f, to: (@convention(c) (AnyObject, Selector, CGPoint, ObjCBool) -> Void).self)(o, sel, point, ObjCBool(flag))
        }
    }
}
#endif
