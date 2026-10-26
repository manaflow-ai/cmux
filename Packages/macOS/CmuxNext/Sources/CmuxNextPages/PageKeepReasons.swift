package import CmuxNextHibernation
import CmuxNextSettings

/// The keep reasons a ``PageWebView`` holds itself (p13-webui.md 3.C), beside its load
/// (``PageLoadState``) and focus: what its document said through `cmux.page.keepAlive`, and what the
/// host has open on it (a confirmation sheet, a context menu, a drag over it, dictation).
///
/// Page script can only add reasons, as a Chrome page can only add a `CannotFreezeReason` by what
/// it does (components/performance_manager/public/freezing/cannot_freeze_reason.h): it may set and
/// end only ``pageSettable`` reasons of its own, never one the host holds or one the planner
/// derives, and nothing it sends lets a page freeze sooner. Its reasons end with its document
/// (``documentEnded()``: a reload, a crash, a navigation, a pooled rebind), as a Chrome page's
/// state ends with its `RenderFrameHost`.
///
/// ```swift
/// view.keepReasons.begin(.dictation)   // the dictation owner
/// view.keepReasons.end(.dictation)
/// ```
@MainActor
package final class PageKeepReasons {
    package typealias KeepReason = PageLifecyclePlanner.KeepReason

    /// The reasons page script may set: what only its document knows (edits, a form, a
    /// `beforeunload`, a draft, its own dictation or capture, a drop it still reads, sound, a peer
    /// connection, a device, a lock). The planner's own (visible, recently visible, most recently
    /// used, the settings), the host's (loading, focused, inspector, popup, confirmation) and the
    /// owners' (an agent turn, a shell command, pinned, remote, preload) are never the page's to set.
    package static let pageSettable: Set<KeepReason> = [
        .userEdits, .formInteraction, .beforeUnload, .draft, .dictation, .capture, .fileDrop, .audible, .webRTC,
        .connectedDevice, .webLock,
    ]

    /// The reasons the current document set.
    package private(set) var fromPage: Set<KeepReason> = []
    /// The host's holds, counted: two confirmation sheets end with the second.
    private var holds: [KeepReason: Int] = [:]
    /// The page the lifecycle knows this by (the view).
    weak var owner: AnyObject?
    /// The page lifecycle that holds the page (``PageLifecycleTarget/reportsReasonChanges(to:)``).
    weak var lifecycle: PageLifecycle?

    package init() {}

    /// Every reason held now, the page's and the host's.
    package var current: Set<KeepReason> { fromPage.union(holds.keys) }

    /// The host has `reason` open on the page from now on (a sheet, a menu, a drag, dictation).
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
