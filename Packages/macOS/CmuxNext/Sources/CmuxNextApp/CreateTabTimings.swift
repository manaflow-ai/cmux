import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextSignposts
import CmuxNextTerminal

/// The `create.tab` intervals of new tabs waiting for their first themed content frame (p09-observability task 030,
/// PL-cef-tab), keyed by the tab's id in its pane's strip. The content cache owns it.
///
/// A create path begins the interval in the key's turn (``begin(_:)``) and names its tab once the tab exists
/// (``expect(_:tab:standIn:)``): a stand-in shown in that turn also gets its instant. The pane that shows the tab
/// reports its content (``presented(_:content:)``), and the interval ends at that content's first frame: a terminal's
/// first IOSurface, a page's first contentful paint, an agent or page tab's first paint, else the commit that shows
/// it. A tab that closes first ends with outcome closed (``released(_:)``, or the content closing). Each interval
/// ends exactly once.
///
/// The daemon's tab that replaces a stand-in shows the same content under its own id: a show of that content under
/// a new id moves the wait there, so a close of the daemon's tab still ends it.
@MainActor
final class CreateTabTimings {
    /// How a shown tab's content reports its first frame.
    struct FirstFrame {
        /// The content's identity: the same content shown under another tab id is the same wait.
        let content: ObjectIdentifier
        /// Starts the wait; `done` runs once with how it ended. Returns what cancels the wait, if anything.
        let wait: @MainActor (_ done: @escaping @MainActor (CreateTabInterval.Outcome) -> Void) -> (@MainActor () -> Void)?
    }

    private struct Waiting {
        let interval: CreateTabInterval
        /// The content whose first frame it waits for, once shown.
        var content: ObjectIdentifier?
        var cancel: (@MainActor () -> Void)?
    }

    private var waiting: [String: Waiting] = [:]
    private let signposter: Signposter
    private let boundary: CommitBoundary

    /// - Parameters:
    ///   - signposter: The `create` signposter (tests pass one on their own trace runtime).
    ///   - boundary: The commit boundary content with no frame signal of its own ends at.
    init(signposter: Signposter = .create, boundary: CommitBoundary = CommitBoundary()) {
        self.signposter = signposter
        self.boundary = boundary
    }

    /// The tabs waiting for their first frame.
    var waitingTabs: Set<String> { Set(waiting.keys) }

    /// Begins a new tab's interval now: call it first in the key's turn.
    func begin(_ kind: CreateTabInterval.Kind) -> CreateTabInterval {
        CreateTabInterval(kind: kind, signposter: signposter)
    }

    /// `interval`'s tab is `key`; `standIn`: it is a stand-in shown in this turn (its instant goes at this turn's
    /// commit). Call it before the pane shows the tab.
    func expect(_ interval: CreateTabInterval, tab key: String, standIn: Bool) {
        guard interval.isOpen else { return }
        if let earlier = waiting.removeValue(forKey: key) { end(earlier, .closed) }
        waiting[key] = Waiting(interval: interval)
        if standIn { interval.standInShown(at: boundary) }
    }

    /// Pane content of tab `key` is shown now.
    func presented(_ key: String, content: TabContent) {
        guard !waiting.isEmpty else { return }
        presented(key, firstFrame: content.createTabFirstFrame)
    }

    /// ``presented(_:content:)`` with the content's frame signal (tests pass their own).
    func presented(_ key: String, firstFrame: FirstFrame) {
        if waiting[key] == nil, let moved = waiting.first(where: { $0.value.content == firstFrame.content })?.key {
            waiting[key] = waiting.removeValue(forKey: moved) // the daemon's tab shows its stand-in's content
        }
        guard var entry = waiting[key], entry.content == nil else { return }
        entry.content = firstFrame.content
        waiting[key] = entry
        let interval = entry.interval
        let cancel = firstFrame.wait { [weak self] outcome in self?.finish(interval, outcome) }
        // The wait may have ended at once (a page that painted already).
        if interval.isOpen { waiting[key]?.cancel = cancel }
    }

    /// The daemon's tab `real` took stand-in `key`'s place: the wait follows it.
    func rekey(_ key: String, to real: String) {
        guard key != real, let entry = waiting.removeValue(forKey: key) else { return }
        if let earlier = waiting.updateValue(entry, forKey: real) { end(earlier, .closed) }
    }

    /// Tab `key` closed: its interval ends as closed when it is still waiting.
    func released(_ key: String) {
        guard let entry = waiting.removeValue(forKey: key) else { return }
        end(entry, .closed)
    }

    private func finish(_ interval: CreateTabInterval, _ outcome: CreateTabInterval.Outcome) {
        if let key = waiting.first(where: { $0.value.interval === interval })?.key { waiting[key] = nil }
        interval.end(outcome)
    }

    private func end(_ entry: Waiting, _ outcome: CreateTabInterval.Outcome) {
        entry.cancel?()
        entry.interval.end(outcome)
    }
}

extension CreateTabInterval.Kind {
    /// The kind of a new browser tab on `engine`.
    init(engine: CmuxNextDaemon.BrowserEngine) {
        self = engine == .cef ? .chromium : .webkit
    }
}

extension TabContent {
    /// How this content reports its first themed frame for `create.tab`.
    @MainActor var createTabFirstFrame: CreateTabTimings.FirstFrame {
        let identity = ObjectIdentifier(view)
        switch self {
        case .terminal(let entry):
            let session = entry.session
            return .init(content: identity) { done in
                let watch = TerminalFirstFrameWatch(session: session, shown: { done(.shown) }, closed: { done(.closed) })
                return { watch.cancel() }
            }
        case .browser(let entry):
            guard let page = entry.tab as? any BrowserFirstContentFrameReporting, page.loadsDocument else { return .atCommit(identity) }
            return .init(content: identity) { done in
                page.whenFirstContentFrame { done($0 ? .shown : .closed) }
                return nil
            }
        case .agent(let view): return .painted(view, identity)
        case .page(let view): return .painted(view, identity)
        case .placeholder, .notice, .conversation: return .atCommit(identity)
        }
    }
}

extension CreateTabTimings.FirstFrame {
    /// Content with no frame signal of its own: it shows at the commit after this turn.
    static func atCommit(_ content: ObjectIdentifier, boundary: CommitBoundary = CommitBoundary()) -> Self {
        .init(content: content) { done in
            boundary.after { _ in done(.shown) }
            return nil
        }
    }

    /// Content transparent until its document paints (an agent page, a page tab): it shows at its first paint.
    @MainActor static func painted(_ gated: any PaneFirstPaintGated, _ content: ObjectIdentifier) -> Self {
        guard gated.awaitsFirstPaint else { return .atCommit(content) }
        return .init(content: content) { done in
            gated.whenFirstPainted { done(.shown) }
            return nil
        }
    }
}
