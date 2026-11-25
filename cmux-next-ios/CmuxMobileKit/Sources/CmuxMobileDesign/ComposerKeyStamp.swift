#if os(iOS)
import OSLog
import QuartzCore
import UIKit

/// Key-to-glyph stamps for a composer field, in every build: a signpost
/// interval (`dev.cmux.mobile`, category `composer`, name `key_glyph`) from
/// the key event to the frame that shows its glyph, with an event when the
/// text changes. Instruments' os_signpost track reads the same two numbers on
/// an iPhone that the simulator UI test reads from `InputLatencyTrace`:
///
/// - `<field id>_key_glyph`: key event to display-link present (the frame's
///   `targetTimestamp`), ms;
/// - `<field id>_key_wait`: key event to the text view receiving it (a
///   hardware key only; the software keyboard's tap has no event here), ms;
/// - `<field id>_view_update`: one per SwiftUI `updateUIView` of the field
///   (its ms), so a re-render driven by anything but the field shows up while
///   typing.
///
/// The key event is the `UIPressesEvent` timestamp of a hardware key, else
/// the moment `insertText` begins. Off (no signpost recording and no trace),
/// a keystroke costs one flag read.
@MainActor
public final class ComposerKeyStamp: NSObject {
    public static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "composer")

    public static var isActive: Bool {
        #if DEBUG
        if InputLatencyTrace.isEnabled { return true }
        #endif
        return signposter.isEnabled
    }

    private struct Pending {
        var key: CFTimeInterval
        var state: OSSignpostIntervalState
    }

    private let field: () -> String
    private var pressedAt: CFTimeInterval?
    private var pending: [Pending] = []
    private var link: CADisplayLink?

    /// `field` names the samples (the field's accessibility identifier).
    public init(field: @escaping () -> String) {
        self.field = field
    }

    /// A hardware key went down (`pressesBegan`), at the event's timestamp.
    public func pressed(at timestamp: TimeInterval) {
        guard Self.isActive else { return }
        pressedAt = timestamp
    }

    /// Wraps the text view's own insertion of a typed key.
    public func insert(_ body: () -> Void) {
        guard Self.isActive else { return body() }
        let received = CACurrentMediaTime()
        // A press older than 250 ms is not this key's (it was a command, or held).
        let key = pressedAt.flatMap { received - $0 < 0.25 && received >= $0 ? $0 : nil } ?? received
        pressedAt = nil
        let state = Self.signposter.beginInterval("key_glyph", id: Self.signposter.makeSignpostID())
        body()
        Self.signposter.emitEvent("text_change")
        let name = field()
        if key < received { record("\(name)_key_wait", ms: (received - key) * 1000) }
        pending.append(Pending(key: key, state: state))
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// The first frame after the insertion presents its glyph at `targetTimestamp`.
    @objc private func frame(_ link: CADisplayLink) {
        let present = max(link.targetTimestamp, CACurrentMediaTime())
        let name = field()
        for item in pending {
            Self.signposter.endInterval("key_glyph", item.state)
            record("\(name)_key_glyph", ms: (present - item.key) * 1000)
        }
        pending.removeAll()
        link.invalidate()
        self.link = nil
    }

    /// Times one `updateUIView` of a composer field.
    public static func viewUpdate(_ view: UIView, _ body: () -> Void) {
        guard isActive else { return body() }
        let start = CACurrentMediaTime()
        body()
        let ms = (CACurrentMediaTime() - start) * 1000
        signposter.emitEvent("view_update")
        record("\(view.accessibilityIdentifier ?? "composer")_view_update", ms: ms)
    }

    private func record(_ kind: String, ms: Double) { Self.record(kind, ms: ms) }

    private static func record(_ kind: String, ms: Double) {
        #if DEBUG
        InputLatencyTrace.shared?.sample(kind, ms: ms)
        #endif
    }
}
#endif
