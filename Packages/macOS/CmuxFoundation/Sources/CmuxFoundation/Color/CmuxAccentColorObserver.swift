public import AppKit

/// Watches the inputs of ``CmuxAccentColor`` (the `app.accentColor` mode and,
/// while following it, the macOS accent) and posts
/// ``CmuxAccentColor/didChangeNotification`` when the resolved accent changes.
///
/// Draw-based chrome resolves the accent on every draw, so the observer also
/// marks every window's views for display. Layer-backed chrome that caches a
/// `CGColor` re-applies it from the notification.
@MainActor
public final class CmuxAccentColorObserver {
    public static let shared = CmuxAccentColorObserver()

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    private var lastFingerprint: String?

    public init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    public func startObserving() {
        guard tokens.isEmpty else { return }
        lastFingerprint = Self.fingerprint(defaults: defaults)
        for name in [NSColor.systemColorsDidChangeNotification, UserDefaults.didChangeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            })
        }
    }

    /// Posts the change notification when the resolved accent differs from
    /// the last one seen. Returns whether it posted.
    @discardableResult
    public func refresh() -> Bool {
        let next = Self.fingerprint(defaults: defaults)
        guard next != lastFingerprint else { return false }
        lastFingerprint = next
        center.post(name: CmuxAccentColor.didChangeNotification, object: nil)
        for window in NSApp?.windows ?? [] {
            if let root = window.contentView?.superview ?? window.contentView {
                Self.markForDisplay(root)
            }
        }
        return true
    }

    /// Identifies the resolved accent: the mode plus both scheme colors.
    public static func fingerprint(defaults: UserDefaults = .standard) -> String {
        let mode = CmuxAccentColorMode.stored(in: defaults)
        let light = CmuxAccentColor.nsColor(isDark: false, mode: mode).hexString()
        let dark = CmuxAccentColor.nsColor(isDark: true, mode: mode).hexString()
        return "\(mode.rawValue):\(light):\(dark)"
    }

    private static func markForDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markForDisplay(subview)
        }
    }
}
