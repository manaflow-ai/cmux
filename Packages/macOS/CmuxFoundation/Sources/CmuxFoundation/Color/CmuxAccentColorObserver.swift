public import AppKit

/// Resolves ``CmuxAccentColor`` from `app.accentColor` (mode and custom
/// color) once per change and
/// posts ``CmuxAccentColor/didChangeNotification`` (with itself as the
/// object) when the resolved accent changes: when the setting changes, or
/// when the macOS accent changes while the setting follows it.
///
/// The app delegate owns one instance and injects ``current`` into the
/// sidebar snapshot, the SwiftUI environment and AppKit chrome.
@MainActor
public final class CmuxAccentColorObserver {
    public private(set) var current: CmuxAccentColor

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private var systemColorsToken: (any NSObjectProtocol)?
    private var modeObservation: NSKeyValueObservation?
    private var customHexObservation: NSKeyValueObservation?

    public init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
        self.current = .stored(in: defaults)
    }

    public func startObserving() {
        guard modeObservation == nil else { return }
        modeObservation = defaults.observe(\.appAccentColor, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        customHexObservation = defaults.observe(\.appAccentColorCustomHex, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        systemColorsToken = center.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    /// Re-resolves the accent and posts the change notification when it
    /// draws differently than before. Returns whether it posted.
    @discardableResult
    public func refresh() -> Bool {
        let next = CmuxAccentColor.stored(in: defaults)
        guard next != current else { return false }
        current = next
        center.post(name: CmuxAccentColor.didChangeNotification, object: self)
        return true
    }
}

extension UserDefaults {
    /// KVO hook for `app.accentColor`; the property name matches the
    /// UserDefaults key so observation fires only for this key.
    @objc dynamic var appAccentColor: String? {
        string(forKey: CmuxAccentColorMode.userDefaultsKey)
    }

    /// KVO hook for the custom accent hex, named after its UserDefaults key.
    @objc dynamic var appAccentColorCustomHex: String? {
        string(forKey: CmuxAccentColorMode.customHexUserDefaultsKey)
    }
}
