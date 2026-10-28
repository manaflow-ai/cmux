#if DEBUG && os(iOS)
import CmuxMobileAgentChat
import GameController
import QuartzCore
import UIKit

/// `-cmux-mobile-kbd-pin-trace`: one line per display frame to
/// `Documents/kbd-pin-trace.txt` with the keyboard and the focused composer
/// field as drawn (presentation layers), for every composer in the app (Chief,
/// agent chat, terminal), plus a line per keyboard notification
/// (verify/keyboard-pin.md, `verify/scripts/kbd_pin_trace.py`).
///
/// Read-only: it never changes a view, a responder or a layout.
@MainActor
final class KeyboardPinTrace: NSObject {
    static let flag = "-cmux-mobile-kbd-pin-trace"
    /// The composers' text fields, in the order a tie is broken.
    static let fieldIDs = ["conversation.composer.text", "terminal.composer.field", "chat.composer.field"]

    private static var shared: KeyboardPinTrace?
    private var link: CADisplayLink?
    private let handle: FileHandle?
    private let start = CACurrentMediaTime()

    static func startIfRequested() {
        guard shared == nil, CommandLine.arguments.contains(flag) else { return }
        shared = KeyboardPinTrace()
    }

    private override init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("kbd-pin-trace.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        super.init()
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
                    self?.write(String(format: "t=%.4f ev=%@ end=%.1f,%.1f,%.1f,%.1f dur=%.3f curve=%d local=%d",
                                       CACurrentMediaTime() - (self?.start ?? 0), label,
                                       end.minX, end.minY, end.width, end.height, duration, curve, local ? 1 : 0))
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
            let rect = KeyboardProbe.onScreen(field, in: window)
            parts.append(String(format: "field=%@ fy=%.2f fb=%.2f fx=%.1f fw=%.1f fr=%d",
                                field.accessibilityIdentifier ?? "?", rect.minY, rect.maxY, rect.minX, rect.width,
                                field.isFirstResponder ? 1 : 0))
            if let scroll = Self.content(behind: field, in: window) {
                let frame = KeyboardProbe.onScreen(scroll, in: window)
                let bounds = (scroll.layer.presentation() ?? scroll.layer).bounds
                // The content's bottom edge on screen.
                let bottom = frame.minY + scroll.contentSize.height - bounds.minY
                parts.append(String(format: "cb=%.2f off=%.2f inb=%.2f trk=%d", bottom, bounds.minY, scroll.contentInset.bottom, scroll.isTracking ? 1 : 0))
            }
        } else {
            parts.append("field=-")
        }
        write(parts.joined(separator: " "))
    }

    /// The keyboard as drawn, window coordinates; nil when none is on screen.
    static func keyboardRect(in window: UIWindow) -> CGRect? {
        guard let scene = window.windowScene else { return nil }
        for w in scene.windows where NSStringFromClass(type(of: w)).contains("TextEffects") {
            guard let host = KeyboardProbe.find(in: w, where: { NSStringFromClass(type(of: $0)).contains("RemoteKeyboardPlaceholder") }) else { continue }
            let rect = window.convert(KeyboardProbe.onScreen(host, in: w), from: w)
            guard rect.height > 1, rect.minY < window.bounds.maxY else { return nil }
            return rect
        }
        return nil
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
        return found.max { KeyboardProbe.onScreen($0, in: window).maxY < KeyboardProbe.onScreen($1, in: window).maxY }
    }

    /// The tallest scroll view (not a text view) under the field's column.
    static func content(behind field: UIView, in window: UIWindow) -> UIScrollView? {
        let fieldRect = KeyboardProbe.onScreen(field, in: window)
        var best: UIScrollView?
        var bestHeight: CGFloat = 0
        func walk(_ view: UIView) {
            guard !view.isHidden else { return }
            if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height > bestHeight {
                let rect = KeyboardProbe.onScreen(scroll, in: window)
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
#endif
