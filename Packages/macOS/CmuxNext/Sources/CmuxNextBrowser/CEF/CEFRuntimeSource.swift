/// Where ``CEFEngine`` finds the Chromium runtime: embedded in the app
/// bundle, or a pack the app downloads on first use
/// (plans/cmux-next/bundle-size-DESIGN.md section 6), and where its browser
/// process runs (``backend``).
///
/// The App owns one source per process. A build that embeds Chromium creates
/// it with the bundled layout and never changes it. A build that downloads
/// Chromium creates it with no layout and a pending reason, reports progress
/// with ``update(pending:)``, and calls ``install(_:)`` once the pack is in:
/// the next Chromium tab then starts Chromium. Chromium can start only once
/// per process, so the layout never changes after it is set, and the backend
/// never changes at all.
public final class CEFRuntimeSource {
    /// The runtime to start, nil until one is available.
    public private(set) var layout: CEFRuntimeLayout?
    /// Why there is no layout yet; nil means "not bundled" for a build with
    /// no pack.
    public private(set) var pending: CEFUnavailableReason?
    /// The Chromium Host's supervisor in host mode: `CEFRuntime.start` asks it
    /// for the host's wire and never maps the framework in this process. Nil
    /// keeps Chromium in this process.
    public let hostSupervisor: (any ChromiumHostSupervising)?

    /// Creates a source.
    ///
    /// - Parameters:
    ///   - layout: The embedded (or already installed) runtime, nil when none is available yet.
    ///   - pending: Why it is missing (`downloading`), nil for a build with no pack.
    ///   - hostSupervisor: The Chromium Host's supervisor for ``BrowserBackend/host``
    ///     (`BrowserHostTunables.backend(in:)`), nil for ``BrowserBackend/inProcess``.
    public init(layout: CEFRuntimeLayout?, pending: CEFUnavailableReason? = nil,
                hostSupervisor: (any ChromiumHostSupervising)? = nil) {
        self.layout = layout
        self.pending = layout == nil ? pending : nil
        self.hostSupervisor = hostSupervisor
    }

    /// Where Chromium's browser process runs: in the Chromium Host when the
    /// source has a supervisor, otherwise in this process.
    public var backend: BrowserBackend { hostSupervisor == nil ? .inProcess : .host }

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
