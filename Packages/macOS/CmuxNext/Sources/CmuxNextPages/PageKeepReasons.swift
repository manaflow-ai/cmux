package import CmuxNextHibernation
import CmuxNextSettings

/// The keep reasons a ``PageWebView`` holds itself (p13-webui.md 3.C), beside its load
/// (``PageLoadState``) and focus: what its document said through `cmux.page.keepAlive`, and what the
/// host has open on it (a confirmation sheet, a menu or popup, a dropped file it still reads, Web
/// Inspector, the agent pane's dictation).
///
/// Page script may set only what a Chrome renderer reports about its own document: form
/// interaction, user edits and a `beforeunload` handler reach Chrome's browser from Blink
/// (DocumentResourceCoordinator::SetHadFormInteraction and SetHadUserEdits,
/// RenderFrameHostImpl::SuddenTerminationDisablerChanged). What Chrome's browser observes itself
/// (sound, locks, devices, peer connections: freezing_policy.cc reads browser-side observers)
/// page script cannot claim here either. A page's reasons end with its document (``documentEnded()``: a
/// reload, a crash, a navigation, a pooled rebind), as a Chrome page's state ends with its
/// `RenderFrameHost`, and nothing it sends lets a page freeze sooner.
///
/// ```swift
/// view.keepReasons.begin(.confirmation)   // the sheet's owner
/// view.keepReasons.end(.confirmation)
/// ```
@MainActor
package final class PageKeepReasons {
    package typealias KeepReason = PageLifecyclePlanner.KeepReason

    /// The reasons page script may set: what only its document knows (edits, a form, a
    /// `beforeunload`, an unsent draft) and its own capture (the agent page's composer, 089). The
    /// planner's (visible, recently visible, most recently used, the settings), the host's (loading,
    /// focused, inspector, popup, confirmation, file drop, dictation, sound, a peer connection, a
    /// device, a lock) and the owners' (an agent turn, a shell command, pinned, remote, preload) are
    /// never the page's to set.
    package static let pageSettable: Set<KeepReason> = [.userEdits, .formInteraction, .beforeUnload, .draft, .capture]

    /// The reasons the current document set.
    package private(set) var fromPage: Set<KeepReason> = []
    /// The host's holds, counted: two confirmation sheets end with the second.
    private var holds: [KeepReason: Int] = [:]
    /// The page the lifecycle knows this by (the view).
    weak var owner: AnyObject?
    /// The page lifecycle that holds the page (``PageLifecycleTarget/reportsReasonChanges(to:)``).
    weak var lifecycle: PageLifecycle?
    /// The page view's own follower of ``current`` (a hidden page held visible to WebKit, PageWebView+HostHidden.swift).
    var onChange: (@MainActor () -> Void)?

    package init() {}

    /// Every reason held now, the page's and the host's.
    package var current: Set<KeepReason> { fromPage.union(holds.keys) }

    /// The host has `reason` open on the page from now on (a sheet, a menu, a drop it reads, dictation).
    package func begin(_ reason: KeepReason) {
        let count = holds[reason, default: 0]
        holds[reason] = count + 1
        if count == 0, !fromPage.contains(reason) { changed() }
    }

    /// One ``begin(_:)`` of `reason` ended.
    package func end(_ reason: KeepReason) {
        guard let count = holds[reason] else { return }
        holds[reason] = count > 1 ? count - 1 : nil
        if count == 1, !fromPage.contains(reason) { changed() }
    }

    /// The agent pane's dictation into the page started (`true`) or ended (`false`): its `dictation`
    /// reason, one begin and one end per session (``begin(_:)``).
    package func dictation(_ runs: Bool) {
        if runs { begin(.dictation) } else { end(.dictation) }
    }

    /// The document's `cmux.page.keepAlive {reason, on}`.
    func setFromPage(_ reason: KeepReason, on: Bool) {
        let before = current
        if on { fromPage.insert(reason) } else { fromPage.remove(reason) }
        if current != before { changed() }
    }

    /// The document went away: what it set ends with it; the host's holds stay.
    func documentEnded() {
        guard !fromPage.isEmpty else { return }
        let before = current
        fromPage.removeAll()
        if current != before { changed() }
    }

    private func changed() {
        onChange?()
        if let owner { lifecycle?.pageReasonsDidChange(owner) }
    }

    /// The reason and state of a `cmux.page.keepAlive` call: `{reason, on}`, `reason` one of
    /// ``pageSettable``'s names (`user_edits`).
    static func pageRequest(_ params: JSONValue) throws(PageError) -> (reason: KeepReason, on: Bool) {
        guard case .object(let fields) = params else { throw PageError.invalidParams("params must be an object") }
        guard let name = fields["reason"]?.stringValue else { throw PageError.invalidParams("reason must be a string") }
        guard let on = fields["on"]?.boolValue else { throw PageError.invalidParams("on must be a boolean") }
        guard let reason = KeepReason(rawValue: name), pageSettable.contains(reason) else {
            throw PageError.invalidParams("a page cannot set the keep reason \(name)")
        }
        return (reason, on)
    }
}
