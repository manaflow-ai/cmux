/// The always-on `switch.tab` interval (``SignpostName/switchTab``): one async pair per tab switch, in every build,
/// from the switch intent to the commit that shows the destination tab's content.
///
/// Modeled on Chrome's tab switch time (`Browser.Tabs.TotalSwitchDuration2`): `TabStripModel` activation stores a
/// visible-time request keyed to the destination WebContents (`WebContentsImpl::SetTabSwitchStartTime`,
/// content/browser/renderer_host/visible_time_request_trigger.h), and the request is dropped when that tab hides.
/// Chrome splits the time by the destination's state (saved frames, loaded, not loaded); here the ``Kind`` is that
/// split:
/// - ``Kind/cold``: the destination has no live content yet; its content shows a frame after the intent.
/// - ``Kind/warm``: live content of the app's own (a terminal, an agent, a WebKit page, an app page).
/// - ``Kind/page``: a live Chromium page, shown by the page window.
///
/// Each switch records its destination key, and only that key's show ends it: ``contentShown(_:key:)`` ends it at the
/// ``CommitBoundary`` of the turn that put the destination's content in the pane. A re-show of another tab (a store
/// change, a resume) ends nothing.
///
/// The end is the app's commit, not the destination's drawn frame. Chrome ends its event at the renderer's
/// presentation feedback (`ContentToVisibleTimeReporter`); cmux has no such signal from the Chromium fork yet, so a
/// Chromium page's switch is a lower bound: the page takes a ``PageShow`` (``pageShow(_:key:)``), its page window's
/// show (`CEFLayerHosting.pageShown`, after `tab_activate`) marks it, and a committed end of a marked switch carries
/// `end=page_activated` (ring code `EndCode.pageActivated`) and stays out of MetricKit, so the histogram holds only
/// app-drawn content.
///
/// Every begin gets exactly one end. A second intent of the same owner, or ``forget(_:)`` (the pane went away or its
/// workspace stopped drawing), ends the open switch as missed (`commit=missed`), so readers and MetricKit drop it; an
/// end that comes after that (a boundary in flight, a stale ``PageShow``) finds another serial and writes nothing.
///
/// Ring: AB/AE keyed by the interval's `OSSignpostID`; begin `arg0` holds the kind in bits 0-7 (0 cold, 1 warm,
/// 2 page) and the input age in us in the top 24 bits (all ones without an input event); end `arg0` the end code
/// (0 ended, 1 missed, 3 page activated).
///
/// ```swift
/// tabSwitch.began(pane, to: key, kind: .warm, inputAgeMilliseconds: age)
/// tabSwitch.contentShown(pane, key: key)
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

    /// A switch to a live Chromium page (Chrome's visible-time request, held by the destination): the page window's
    /// show calls ``pageShown()``.
    @MainActor
    public struct PageShow {
        fileprivate weak var signpost: TabSwitchSignpost?
        fileprivate let owner: ObjectIdentifier
        fileprivate let serial: UInt64

        /// The page window shows the destination now (`tab_activate` sent): the switch ends at this turn's commit,
        /// as `end=page_activated`. A switch that already ended (superseded, forgotten) writes nothing.
        public func pageShown() {
            signpost?.pageActivated(owner, serial: serial)
        }
    }

    private struct Open {
        var serial: UInt64
        /// The destination tab: only its show ends the switch.
        var key: String
        var interval: SignpostInterval
        /// The page window showed the destination in the turn the switch ends in.
        var pageActivated = false
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

    /// A switch intent of `owner` (a pane) to the tab `key`: begins its interval and ends the one it left open as
    /// missed. Callers begin one only for a selection that will be shown (allowed by the run, pane drawing).
    ///
    /// - Parameters:
    ///   - owner: The pane whose selection changes.
    ///   - key: The destination tab.
    ///   - kind: What the destination is now.
    ///   - inputAgeMilliseconds: The triggering event's age when the intent began, or -1 without one.
    public func began(_ owner: AnyObject, to key: String, kind: Kind, inputAgeMilliseconds: Double) {
        let id = ObjectIdentifier(owner)
        if let superseded = open.removeValue(forKey: id) { signposter.end(.switchTab, superseded.interval, .missed) }
        lastSerial &+= 1
        let arg0 = kind.rawValue | Signposter.inputAgeBits(milliseconds: inputAgeMilliseconds)
        open[id] = Open(serial: lastSerial, key: key, interval: signposter.begin(.switchTab, kind.message, arg0: arg0))
    }

    /// The request a Chromium page holds for the switch of `owner` to `key`: its page window's show marks the switch.
    /// Nil when `owner` has no open switch to `key` (a re-show of the tab already shown) or it is already ending.
    public func pageShow(_ owner: AnyObject, key: String) -> PageShow? {
        let id = ObjectIdentifier(owner)
        guard let switched = open[id], switched.key == key, !switched.ending else { return nil }
        return PageShow(signpost: self, owner: id, serial: switched.serial)
    }

    /// `owner` put the content of `key` in the pane this turn: a switch to `key` ends at this turn's commit.
    public func contentShown(_ owner: AnyObject, key: String) {
        let id = ObjectIdentifier(owner)
        guard let switched = open[id], switched.key == key else { return }
        end(id, serial: switched.serial)
    }

    /// `owner` went away or stopped drawing (its workspace hid): a switch it began and never showed ends as missed,
    /// as Chrome drops a visible-time request when its tab hides.
    public func forget(_ owner: AnyObject) {
        guard let switched = open.removeValue(forKey: ObjectIdentifier(owner)) else { return }
        signposter.end(.switchTab, switched.interval, .missed)
    }

    private func pageActivated(_ id: ObjectIdentifier, serial: UInt64) {
        guard open[id]?.serial == serial else { return }
        open[id]?.pageActivated = true
        end(id, serial: serial)
    }

    /// Ends the switch `serial` of `id` at this turn's commit boundary, once.
    private func end(_ id: ObjectIdentifier, serial: UInt64) {
        guard let switched = open[id], switched.serial == serial, !switched.ending else { return }
        open[id]?.ending = true
        boundary { [weak self] outcome in self?.boundaryFired(id, serial: serial, outcome) }
    }

    private func boundaryFired(_ id: ObjectIdentifier, serial: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let switched = open[id], switched.serial == serial else { return }
        open[id] = nil
        if switched.pageActivated, outcome == .committed {
            signposter.endPageActivated(.switchTab, switched.interval)
        } else {
            signposter.end(.switchTab, switched.interval, outcome)
        }
    }
}
