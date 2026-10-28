public import CmuxNextWakeups
import Darwin

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
    /// Host mode: the host's extension popups, side panel, DevTools, popup windows and page popups
    /// show in cmux panels and panes (feature `chromiumHostWidgets`, set by the App). Read when the
    /// runtime adopts the source, before Chromium starts; in process it changes nothing.
    public var showsHostWidgets = false
    /// Host mode: hosted pages' keys, clicks, moves and wheel ticks go through the host's input
    /// ring, paced by its acks (feature `chromiumHostInputRing`, set by the App). Read when the
    /// runtime adopts the source; in process it changes nothing.
    public var routesHostInput = false
    /// Host mode: drags onto a page reach it with DragTarget calls (feature `chromiumHostDragIn`, set by
    /// the App). Read when the runtime adopts the source; in process it changes nothing.
    public var takesHostDrags = false
    /// Host mode: a hosted page's resize holds its window's commit on a Core Animation fence until the
    /// page's frame at the new size joins it, one display frame at most (feature `chromiumHostResizeFence`,
    /// set by the App; ``ChromiumHostResizeFence``). Read when the runtime adopts the source.
    public var fencesHostResizes = false
    /// Host mode: a page's `<select>` popups show as cmux menus over the page and the host never shows its
    /// own (feature `chromiumHostPopupMenus`, set by the App; ``ChromiumHostPopupMenus``). Read when the
    /// runtime adopts the source; in process it changes nothing.
    public var drawsHostPopupMenus = false
    /// Host mode: a page's autofill, password and `<datalist>` suggestions show in cmux's list, not
    /// Chromium's popup, which would open in the host (feature `chromiumHostSuggestions`, set by the App).
    /// Read when the runtime adopts the source; in process it changes nothing.
    public var drawsHostSuggestions = false
    /// Host mode: a page's color chooser, device choosers (Bluetooth, USB, HID, Serial) and screen-share picker
    /// show in cmux, not in the host (feature `chromiumHostChoosers`, set by the App; ``ChromiumHostChoosers``).
    /// Read when the runtime adopts the source; in process it changes nothing.
    public var drawsHostChoosers = false
    /// Host mode: a page's file chooser shows cmux's picker on the page's window, and the chosen files
    /// go to the host as paths (feature `chromiumHostFileDialogs`, set by the App; ``ChromiumHostFiles``).
    /// Nil leaves Chromium's own panel, which in host mode opens in the host. Read when the runtime adopts the source.
    public var hostFileDialogs: (any ChromiumFileDialogAnswering)?
    /// Whose children the Chromium helpers are, for listings on any thread: this app in
    /// process; in host mode none until the runtime that adopts this source attaches a host, then that host.
    public let helperParent: ChromiumHelperParent
    /// Host mode: input the Chromium Host's UI thread has not dispatched for 2 s puts "Chromium is busy",
    /// with Wait and Reload Chromium, over the panes that show its pages (feature `chromiumHostHangBanner`,
    /// set by the App; ``ChromiumHostHangMonitor``). Read when the runtime adopts the source.
    public var watchesHostHangs = false
    /// Host mode, with ``watchesHostHangs``: each UI hang of the Chromium Host of 250 ms or more, for the
    /// app's hang reports (set by the App). Read at each hang.
    public var onHostHang: ((ChromiumHostHang) -> Void)?
    /// Host mode: a page's pointer lock and keyboard lock are cmux's, and Escape ends them and the page's
    /// fullscreen (feature `chromiumHostLocks`, set by the App; ``CEFHostLocks``). Read when the runtime
    /// adopts the source; in process it changes nothing.
    public var handlesHostLocks = false
    /// The app's one ``AppEvents`` (`AppServices.appEvents`, set by the App): with ``handlesHostLocks``, a page's
    /// pointer lock ends when the app resigns active. Read when the runtime adopts the source.
    public var appEvents: AppEvents?

    /// Creates a source.
    ///
    /// - Parameters:
    ///   - layout: The embedded (or already installed) runtime, nil when none is available yet.
    ///   - pending: Why it is missing (`downloading`), nil for a build with no pack.
    ///   - hostSupervisor: The Chromium Host's supervisor for ``BrowserBackend/host``
    ///     (`BrowserHostTunables.backend(hostEnabled:)`), nil for ``BrowserBackend/inProcess``.
    public init(layout: CEFRuntimeLayout?, pending: CEFUnavailableReason? = nil,
                hostSupervisor: (any ChromiumHostSupervising)? = nil) {
        self.layout = layout
        self.pending = layout == nil ? pending : nil
        self.hostSupervisor = hostSupervisor
        helperParent = ChromiumHelperParent(hostSupervisor == nil ? getpid() : nil)
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
