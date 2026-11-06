#if DEBUG && os(iOS)
import CmuxMobileSupport
import GameController
import QuartzCore
import UIKit

/// `-cmux-mobile-kbd-pin-trace`: one line per display frame to
/// `Documents/kbd-pin-trace.txt` with the keyboard and the focused composer
/// field as drawn (presentation layers), for every composer in the app (Chief,
/// agent chat, terminal), plus a line per keyboard notification
/// (verify/keyboard-pin.md, `verify/scripts/kbd_pin_trace.py`).
///
/// It never changes a view, a responder or a layout of the app. UI tests read
/// the latest frame from `probe`, a 1 pt label in the key window that takes no
/// touches (ComposerKeyboardPinUITests).
@MainActor
final class KeyboardPinTrace: NSObject {
    static let flag = "-cmux-mobile-kbd-pin-trace"
    /// The composers' text fields, in the order a tie is broken.
    static let fieldIDs = ["conversation.composer.text", "terminal.composer.field", "chat.composer.field"]

    private static var shared: KeyboardPinTrace?
    private var link: CADisplayLink?
    private let handle: FileHandle?
    private let probe = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let start = CACurrentMediaTime()

    static func startIfRequested() {
        guard shared == nil, CommandLine.arguments.contains(flag) else { return }
        shared = KeyboardPinTrace()
    }

    /// A demo's step (`demo=<label>` on the probe and a line in the file).
    static func note(_ label: String) {
        guard let shared else { return }
        shared.demo = label
        shared.write(String(format: "t=%.4f demo=%@", CACurrentMediaTime() - shared.start, label))
    }

    private var demo = "-"
    /// The last keyboard notifications, `name@t:dur/inherited/endY`.
    private var events: [String] = []
    /// The field's bottom edge as drawn, per frame: `jumps` counts frames
    /// where it moved without an animation (KeyboardToggleInterruptUITests).
    private var fieldSteps = FieldStepMeter()

    private override init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("kbd-pin-trace.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        super.init()
        probe.isUserInteractionEnabled = false
        probe.alpha = 0.02
        probe.isAccessibilityElement = true
        probe.accessibilityIdentifier = "debug.kbd-pin"
        probe.accessibilityLabel = "keyboard pin probe"
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "willShow"),
            (UIResponder.keyboardDidShowNotification, "didShow"),
            (UIResponder.keyboardWillHideNotification, "willHide"),
            (UIResponder.keyboardDidHideNotification, "didHide"),
            (UIResponder.keyboardWillChangeFrameNotification, "willChange"),
            (UIResponder.keyboardDidChangeFrameNotification, "didChange"),
        ]
        for (name, label) in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
                let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? -1
                let local = (info[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The keyboard's own animation, which a nested layout pass inherits.
                    let inherited = UIView.inheritedAnimationDuration
                    self.events.append(String(format: "%@@%.2f:%.2f/%.2f/%.0f", label, CACurrentMediaTime() - self.start, duration, inherited, end.minY))
                    if self.events.count > 24 { self.events.removeFirst(self.events.count - 24) }
                    // Where the window sits in the screen's and the scene's
                    // coordinate spaces (an iPhone app on an iPad).
                    var place = ""
                    if let window = self.keyWindow {
                        let inScreen = window.convert(window.bounds, to: window.screen.coordinateSpace)
                        let screen = window.screen.bounds
                        place = String(format: " winscreen=%.1f,%.1f,%.1f,%.1f screen=%.0fx%.0f",
                                       inScreen.minX, inScreen.minY, inScreen.width, inScreen.height, screen.width, screen.height)
                    }
                    self.write(String(format: "t=%.4f ev=%@ end=%.1f,%.1f,%.1f,%.1f dur=%.3f curve=%d local=%d inh=%.3f",
                                      CACurrentMediaTime() - self.start, label,
                                      end.minX, end.minY, end.width, end.height, duration, curve, local ? 1 : 0, inherited) + place)
                }
            }
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window = keyWindow else { return }
        if probe.window !== window { window.addSubview(probe) }
        var parts = [String(format: "t=%.4f", link.targetTimestamp - start)]
        parts.append(String(format: "win=%.0fx%.0f", window.bounds.width, window.bounds.height))
        parts.append("orient=\(window.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0)")
        parts.append("hw=\(GCKeyboard.coalesced == nil ? 0 : 1)")
        if let keyboard = Self.keyboardRect(in: window) {
            parts.append(String(format: "kb=%.2f kbx=%.1f kbw=%.1f kbh=%.1f", keyboard.minY, keyboard.minX, keyboard.width, keyboard.height))
        } else {
            parts.append("kb=-")
        }
        if let field = Self.composerField(in: window) {
            let rect = MobileKeyboardProbe().onScreen(field, in: window)
            parts.append(String(format: "field=%@ fy=%.2f fb=%.2f fx=%.1f fw=%.1f fr=%d",
                                field.accessibilityIdentifier ?? "?", rect.minY, rect.maxY, rect.minX, rect.width,
                                field.isFirstResponder ? 1 : 0))
            fieldSteps.add(time: link.timestamp - start, bottom: rect.maxY)
            if let guide = Self.keyboardGuide(above: field) {
                let frame = guide.owningView.map { window.convert(guide.layoutFrame, from: $0) } ?? .zero
                parts.append(String(format: "kg=%.2f kgh=%.1f", frame.minY, frame.height))
            }
            if let dock = Self.dockGuide(above: field) {
                let frame = dock.owningView.map { window.convert(dock.layoutFrame, from: $0) } ?? .zero
                parts.append(String(format: "dg=%.2f", frame.minY))
            }
            if let scroll = Self.content(behind: field, in: window) {
                let frame = MobileKeyboardProbe().onScreen(scroll, in: window)
                let bounds = (scroll.layer.presentation() ?? scroll.layer).bounds
                // The content's bottom edge on screen.
                let bottom = frame.minY + scroll.contentSize.height - bounds.minY
                parts.append(String(format: "cb=%.2f off=%.2f inb=%.2f trk=%d", bottom, bounds.minY, scroll.contentInset.bottom, scroll.isTracking ? 1 : 0))
            }
        } else {
            parts.append("field=-")
        }
        let line = parts.joined(separator: " ")
        let summary = [
            "fj=\(fieldSteps.jumps)",
            String(format: "fjmax=%.1f", fieldSteps.largestJump),
            "demo=\(demo)",
            "fjlog=" + (fieldSteps.log.isEmpty ? "-" : fieldSteps.log.joined(separator: ",")),
            "evlog=" + (events.isEmpty ? "-" : events.joined(separator: ",")),
        ].joined(separator: " ")
        probe.accessibilityValue = line + " " + summary
        write(line)
    }

    /// The keyboard as drawn, window coordinates; nil when none is on screen.
    static func keyboardRect(in window: UIWindow) -> CGRect? {
        MobileKeyboardProbe().drawnFrame(in: window)
    }

    /// The composer field to follow: the first responder if a composer has
    /// it, else the lowest visible composer field.
    static func composerField(in window: UIWindow) -> UIView? {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let id = view.accessibilityIdentifier, fieldIDs.contains(id) { found.append(view) }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        if let responder = found.first(where: \.isFirstResponder) { return responder }
        return found.max { MobileKeyboardProbe().onScreen($0, in: window).maxY < MobileKeyboardProbe().onScreen($1, in: window).maxY }
    }

    /// The nearest keyboard layout guide an ancestor already has (never
    /// creates one: `keyboardLayoutGuide` would).
    static func keyboardGuide(above field: UIView) -> UIKeyboardLayoutGuide? {
        var view: UIView? = field
        while let current = view {
            if let guide = current.layoutGuides.lazy.compactMap({ $0 as? UIKeyboardLayoutGuide }).first { return guide }
            view = current.superview
        }
        return nil
    }

    /// The nearest `MobileKeyboardDock` guide an ancestor has.
    static func dockGuide(above field: UIView) -> UILayoutGuide? {
        var view: UIView? = field
        while let current = view {
            if let guide = current.layoutGuides.first(where: { $0.identifier == "MobileKeyboardDock" }) { return guide }
            view = current.superview
        }
        return nil
    }

    /// The tallest scroll view (not a text view) under the field's column.
    static func content(behind field: UIView, in window: UIWindow) -> UIScrollView? {
        let fieldRect = MobileKeyboardProbe().onScreen(field, in: window)
        var best: UIScrollView?
        var bestHeight: CGFloat = 0
        func walk(_ view: UIView) {
            guard !view.isHidden else { return }
            if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height > bestHeight {
                let rect = MobileKeyboardProbe().onScreen(scroll, in: window)
                if rect.minX <= fieldRect.midX, rect.maxX >= fieldRect.midX, rect.height > window.bounds.height / 3 {
                    best = scroll
                    bestHeight = scroll.bounds.height
                }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(window)
        return best
    }
}

/// Per-frame steps of the composer field's bottom edge as drawn. A frame is a
/// jump when the field moves faster than any keyboard animation carries it
/// (3600 pt/s: 60 pt in a 60 Hz frame; the keyboard's own spring peaks near
/// 2000 pt/s), or when one step is far larger than the steps on either side
/// of it: a constraint applied outside the animation moves the field in one
/// frame, where an animation, even one cut short, accelerates into it.
struct FieldStepMeter {
    private(set) var jumps = 0
    private(set) var largestJump: CGFloat = 0
    /// The latest jumps, `t:step`.
    private(set) var log: [String] = []
    private var previous: (time: Double, bottom: CGFloat)?
    /// The last step, waiting for the next one to judge it.
    private var pending: (time: Double, step: CGFloat, speed: CGFloat, before: CGFloat)?
    private var lastSpeed: CGFloat = 0

    mutating func add(time: Double, bottom: CGFloat) {
        defer { previous = (time, bottom) }
        guard let previous, time > previous.time else { return }
        let step = bottom - previous.bottom
        let speed = abs(step) / CGFloat(time - previous.time)
        if let pending {
            let neighbors = max(pending.before, speed)
            let spike = pending.speed > 1200 && pending.speed > 3 * neighbors
            if pending.speed > 3600 || spike { record(pending.time, pending.step) }
        }
        pending = (time, step, speed, lastSpeed)
        lastSpeed = speed
    }

    private mutating func record(_ time: Double, _ step: CGFloat) {
        jumps += 1
        largestJump = max(largestJump, abs(step))
        log.append(String(format: "%.2f:%.0f", time, step))
        if log.count > 8 { log.removeFirst(log.count - 8) }
    }
}
#endif
