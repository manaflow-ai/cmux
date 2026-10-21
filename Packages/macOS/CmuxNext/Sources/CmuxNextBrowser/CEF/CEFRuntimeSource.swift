/// Where ``CEFEngine`` finds the Chromium runtime: embedded in the app
/// bundle, or a pack the app downloads on first use
/// (plans/cmux-next/bundle-size-DESIGN.md section 6).
///
/// The App owns one source per process. A build that embeds Chromium creates
/// it with the bundled layout and never changes it. A build that downloads
/// Chromium creates it with no layout and a pending reason, reports progress
/// with ``update(pending:)``, and calls ``install(_:)`` once the pack is in:
/// the next Chromium tab then starts Chromium in this process. Chromium can
/// start only once per process, so the layout never changes after it is set.
public final class CEFRuntimeSource {
    /// The runtime to start, nil until one is available.
    public private(set) var layout: CEFRuntimeLayout?
    /// Why there is no layout yet; nil means "not bundled" for a build with
    /// no pack.
    public private(set) var pending: CEFUnavailableReason?

    /// Creates a source.
    ///
    /// - Parameters:
    ///   - layout: The embedded (or already installed) runtime, nil when none is available yet.
    ///   - pending: Why it is missing (`downloading`), nil for a build with no pack.
    public init(layout: CEFRuntimeLayout?, pending: CEFUnavailableReason? = nil) {
        self.layout = layout
        self.pending = layout == nil ? pending : nil
    }

    /// Why Chromium cannot start from this source, nil when it has a layout.
    public var unavailableReason: CEFUnavailableReason? {
        layout == nil ? (pending ?? .notBundled) : nil
    }

    /// The downloaded runtime is installed: later tabs use it. Ignored when a
    /// layout is already set (Chromium may be running from it).
    ///
    /// - Returns: True when `layout` became the source's layout.
    @discardableResult
    public func install(_ layout: CEFRuntimeLayout) -> Bool {
        guard self.layout == nil else { return false }
        self.layout = layout
        pending = nil
        return true
    }

    /// The download state changed (no effect once a layout is set).
    public func update(pending: CEFUnavailableReason?) {
        guard layout == nil else { return }
        self.pending = pending
    }
}
