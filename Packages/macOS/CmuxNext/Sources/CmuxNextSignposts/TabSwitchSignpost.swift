/// The always-on `switch.tab` interval (``SignpostName/switchTab``): one async pair per tab switch, in every build,
/// from the switch intent to the commit that shows the new tab's content.
///
/// This is Chrome's tab switch time (`Browser.Tabs.TotalSwitchDuration2`): `TabStripModel` activation stores a
/// visible-time request on the destination's WebContents (`WebContentsImpl::SetTabSwitchStartTime`,
/// content/browser/renderer_host/visible_time_request_trigger.h), the request is taken when that content becomes
/// visible, and `ContentToVisibleTimeReporter` (content/browser/renderer_host/content_to_visible_time_reporter.cc)
/// closes the event at that frame. Chrome splits it by the destination's state (saved frames, loaded, not loaded);
/// here the ``Kind`` is that split:
/// - ``Kind/cold``: the destination has no live content yet; its content shows a frame after the intent.
/// - ``Kind/warm``: live content of the app's own (a terminal, an agent, a WebKit page, an app page).
/// - ``Kind/page``: a live Chromium page, shown by the page window.
///
/// The end is the content commit: ``contentShown(_:)`` ends the switch at the ``CommitBoundary`` of the turn that put
/// the content in the pane. A Chromium page draws in its page window, so its switch waits for the page window to show
/// that tab instead: ``pageShow(_:)`` hands the destination a ``PageShow`` (Chrome's request), and the page window's
/// show (`CEFLayerHosting.pageShown`) ends the switch at the boundary of its turn, which can be a later turn than the
/// pane's (a page whose browser is made after the first frame).
///
/// Every begin gets exactly one end. A second intent of the same owner, or ``forget(_:)`` (the pane went away), ends
/// the open switch as missed (`commit=missed`), so readers and MetricKit drop it; an end that comes after that
/// (a boundary in flight, a stale ``PageShow``) finds another serial and writes nothing.
///
/// Ring: AB/AE keyed by the interval's `OSSignpostID`; begin `arg0` holds the kind in bits 0-7 (0 cold, 1 warm,
/// 2 page) and the input age in the top 24 bits (all ones without an input event).
///
/// ```swift
/// tabSwitch.began(pane, kind: .warm, inputAgeMilliseconds: age)
/// tabSwitch.contentShown(pane)
/// ```
@MainActor
public final class TabSwitchSignpost {
    /// What the destination of a switch is when the switch begins.
    public nonisolated enum Kind: UInt64, Sendable, CaseIterable {
        /// No live content yet: it is made and shown a frame after the intent.
        case cold = 0
        /// Live content the app draws.
        case warm = 1
        /// A live Chromium page, drawn by its page window.
        case page = 2

        /// The os_signpost message of a begin.
        var message: String {
            switch self {
            case .cold: "kind=cold"
            case .warm: "kind=warm"
            case .page: "kind=page"
            }
        }
    }

    /// A switch waiting for its Chromium page to show (Chrome's visible-time request): the destination holds it,
    /// and the page window's show calls ``pageShown()`` once.
    @MainActor
    public struct PageShow {
        fileprivate weak var signpost: TabSwitchSignpost?
        fileprivate let owner: ObjectIdentifier
        fileprivate let serial: UInt64

        /// The page window shows the destination now: the switch ends at this turn's commit. A switch that already
        /// ended (superseded, forgotten) writes nothing.
        public func pageShown() {
            signpost?.end(owner, serial: serial)
        }
    }

    private struct Open {
        var serial: UInt64
        var interval: SignpostInterval
        /// The switch ends at its page's show, not at the pane's content commit.
        var waitsForPage = false
        /// Its end is scheduled at a commit boundary.
        var ending = false
    }

    /// Runs a block once after the commit that ends this main run-loop turn.
    public typealias Boundary = @MainActor (_ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void

    private let signposter: Signposter
    private let boundary: Boundary
    private var open: [ObjectIdentifier: Open] = [:]
    private var lastSerial: UInt64 = 0

    /// The app's tab switches: ``Signposter/switch``, ended at the main run loop's ``CommitBoundary``.
    public convenience init() {
        self.init(signposter: .switch) { CommitBoundary().after($0) }
    }

    /// - Parameters:
    ///   - signposter: The switch category's signposter (tests pass one on their own trace runtime).
    ///   - boundary: Runs the end after this turn's commit (tests fire it themselves).
    public init(signposter: Signposter, boundary: @escaping Boundary) {
        self.signposter = signposter
        self.boundary = boundary
    }

    /// How many switches are open (tests, `debug.tab_switch`).
    public var openCount: Int { open.count }

    /// A switch intent of `owner` (a pane): begins its interval and ends the one it left open as missed.
    ///
    /// - Parameters:
    ///   - owner: The pane whose selection changes.
    ///   - kind: What the destination is now.
    ///   - inputAgeMilliseconds: The triggering event's age when the intent began, or -1 without one.
    public func began(_ owner: AnyObject, kind: Kind, inputAgeMilliseconds: Double) {
        let key = ObjectIdentifier(owner)
        if let superseded = open.removeValue(forKey: key) { signposter.end(.switchTab, superseded.interval, .missed) }
        lastSerial &+= 1
        let arg0 = kind.rawValue | Signposter.inputAgeBits(milliseconds: inputAgeMilliseconds)
        open[key] = Open(serial: lastSerial, interval: signposter.begin(.switchTab, kind.message, arg0: arg0))
    }

    /// The switch of `owner` waits for its Chromium page: the returned request ends it when the page window shows
    /// the page. Nil when `owner` has no open switch.
    public func pageShow(_ owner: AnyObject) -> PageShow? {
        let key = ObjectIdentifier(owner)
        guard let switched = open[key], !switched.ending else { return nil }
        open[key]?.waitsForPage = true
        return PageShow(signpost: self, owner: key, serial: switched.serial)
    }

    /// `owner` put its new content in the pane this turn: the switch ends at this turn's commit, unless it waits for
    /// its page.
    public func contentShown(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let switched = open[key], !switched.waitsForPage else { return }
        end(key, serial: switched.serial)
    }

    /// `owner` went away: a switch it began and never showed ends as missed.
    public func forget(_ owner: AnyObject) {
        guard let switched = open.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        signposter.end(.switchTab, switched.interval, .missed)
    }

    /// Ends the switch `serial` of `key` at this turn's commit boundary, once.
    private func end(_ key: ObjectIdentifier, serial: UInt64) {
        guard let switched = open[key], switched.serial == serial, !switched.ending else { return }
        open[key]?.ending = true
        boundary { [weak self] outcome in self?.boundaryFired(key, serial: serial, outcome) }
    }

    private func boundaryFired(_ key: ObjectIdentifier, serial: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let switched = open[key], switched.serial == serial else { return }
        open[key] = nil
        signposter.end(.switchTab, switched.interval, outcome)
    }
}
