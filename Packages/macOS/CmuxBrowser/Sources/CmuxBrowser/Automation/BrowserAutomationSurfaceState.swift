public import Foundation
import Observation

/// The per-browser-surface automation state the control-plane `browser.*`
/// witnesses key by surface id: element references (`@e<n>` selectors), the
/// pinned same-origin frame selector, registered document-start init
/// scripts/styles, the queued in-page dialog backlog, the captured download
/// event backlog, and the not-supported network-interception attempt log.
///
/// `@MainActor` because every mutator and reader is a main-actor path: the
/// `@MainActor` `browser.*` witnesses mutate it directly, and the nonisolated
/// socket-worker JS-eval lane reaches it only through a main-actor hop
/// (`v2MainSync`) to allocate/resolve element refs and read the frame selector.
/// State lives where its callers live; co-locating it on the main actor turns
/// the worker-lane reads into plain main-hopped calls and avoids an actor that
/// would only manufacture an isolation domain the callers already share.
///
/// This is a faithful lift of the per-surface dictionaries that previously lived
/// directly on `TerminalController` (`v2BrowserElementRefs` +
/// `v2BrowserNextElementOrdinal`, `v2BrowserFrameSelectorBySurface`,
/// `v2BrowserInitScriptsBySurface`, `v2BrowserInitStylesBySurface`,
/// `v2BrowserDialogQueueBySurface`, `v2BrowserDownloadEventsBySurface`,
/// `v2BrowserUnsupportedNetworkRequestsBySurface`). Every bound, FIFO rule, and
/// ordinal sequence is preserved exactly.
@MainActor
@Observable
public final class BrowserAutomationSurfaceState {
    /// The bounded depth of a surface's pending-dialog queue (legacy: 16).
    public static var dialogQueueCapacity: Int { 16 }

    /// The bounded depth of a surface's not-supported network-request log
    /// (legacy: 256).
    public static var unsupportedNetworkRequestCapacity: Int { 256 }

    /// An allocated element reference: the surface it belongs to and the CSS
    /// selector it resolves to.
    private struct ElementRefEntry {
        let surfaceId: UUID
        let selector: String
    }

    /// A queued in-page dialog: the captured fields plus the responder closure
    /// that resolves the native dialog when a `browser.dialog.*` command lands.
    private struct PendingDialog {
        let type: String
        let message: String
        let defaultText: String?
        let responder: (_ accept: Bool, _ text: String?) -> Void
    }

    private var nextElementOrdinal: Int = 1
    private var elementRefs: [String: ElementRefEntry] = [:]
    private var frameSelectorBySurface: [UUID: String] = [:]
    private var initScriptsBySurface: [UUID: [String]] = [:]
    private var initStylesBySurface: [UUID: [String]] = [:]
    private var dialogQueueBySurface: [UUID: [PendingDialog]] = [:]
    private var downloadEventsBySurface: [UUID: [[String: Any]]] = [:]
    private var unsupportedNetworkRequestsBySurface: [UUID: [[String: Any]]] = [:]

    /// Creates an empty automation state store.
    public init() {}

    // MARK: - Element references

    /// Allocates a fresh `@e<n>` element reference for `selector` on `surfaceId`
    /// and returns its key. Ordinals are monotonically increasing from 1 across
    /// the store's lifetime, never reused.
    public func allocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(nextElementOrdinal)"
        nextElementOrdinal += 1
        elementRefs[ref] = ElementRefEntry(surfaceId: surfaceId, selector: selector)
        return ref
    }

    /// The selector recorded for `refKey` on `surfaceId`, or `nil` when no entry
    /// exists or the entry belongs to a different surface.
    public func elementRefSelector(refKey: String, surfaceId: UUID) -> String? {
        guard let entry = elementRefs[refKey], entry.surfaceId == surfaceId else { return nil }
        return entry.selector
    }

    // MARK: - Frame selector

    /// The pinned same-origin frame selector for `surfaceId`, or `nil` when the
    /// surface evaluates against the main frame.
    public func frameSelector(surfaceId: UUID) -> String? {
        frameSelectorBySurface[surfaceId]
    }

    /// Pins `surfaceId`'s evaluation to `selector`.
    public func setFrameSelector(_ selector: String, surfaceId: UUID) {
        frameSelectorBySurface[surfaceId] = selector
    }

    /// Clears `surfaceId`'s pinned frame selector, returning evaluation to the
    /// main frame.
    public func clearFrameSelector(surfaceId: UUID) {
        frameSelectorBySurface.removeValue(forKey: surfaceId)
    }

    // MARK: - Init scripts / styles

    /// Appends `script` to `surfaceId`'s document-start init-script cache and
    /// returns the new cache count.
    @discardableResult
    public func appendInitScript(_ script: String, surfaceId: UUID) -> Int {
        var scripts = initScriptsBySurface[surfaceId] ?? []
        scripts.append(script)
        initScriptsBySurface[surfaceId] = scripts
        return scripts.count
    }

    /// Appends `css` to `surfaceId`'s document-start init-style cache and returns
    /// the new cache count.
    @discardableResult
    public func appendInitStyle(_ css: String, surfaceId: UUID) -> Int {
        var styles = initStylesBySurface[surfaceId] ?? []
        styles.append(css)
        initStylesBySurface[surfaceId] = styles
        return styles.count
    }

    // MARK: - Dialog queue

    /// Enqueues a pending in-page dialog for `surfaceId`, keeping the queue
    /// bounded at ``dialogQueueCapacity`` by dropping the oldest entries while
    /// preserving FIFO order for the newest.
    public func enqueueDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        var queue = dialogQueueBySurface[surfaceId] ?? []
        queue.append(PendingDialog(type: type, message: message, defaultText: defaultText, responder: responder))
        if queue.count > Self.dialogQueueCapacity {
            queue.removeFirst(queue.count - Self.dialogQueueCapacity)
        }
        dialogQueueBySurface[surfaceId] = queue
    }

    /// The wire-faithful descriptors of `surfaceId`'s pending dialogs, in queue
    /// order (empty when none are queued).
    public func pendingDialogs(surfaceId: UUID) -> [BrowserAutomationDialogDescriptor] {
        let queue = dialogQueueBySurface[surfaceId] ?? []
        return queue.enumerated().map { index, dialog in
            BrowserAutomationDialogDescriptor(
                index: index,
                type: dialog.type,
                message: dialog.message,
                defaultText: dialog.defaultText
            )
        }
    }

    // MARK: - Download events

    /// Appends a captured download event to `surfaceId`'s backlog.
    public func appendDownloadEvent(_ event: [String: Any], surfaceId: UUID) {
        var queue = downloadEventsBySurface[surfaceId] ?? []
        queue.append(event)
        downloadEventsBySurface[surfaceId] = queue
    }

    /// Removes and returns the oldest queued download event for `surfaceId`, or
    /// `nil` when the backlog is empty.
    public func popDownloadEvent(surfaceId: UUID) -> [String: Any]? {
        guard let first = downloadEventsBySurface[surfaceId]?.first else {
            return nil
        }
        var remaining = downloadEventsBySurface[surfaceId] ?? []
        remaining.removeFirst()
        downloadEventsBySurface[surfaceId] = remaining
        return first
    }

    // MARK: - Not-supported network requests

    /// Appends one not-supported network-interception attempt to `surfaceId`'s
    /// ring log, keeping it bounded at ``unsupportedNetworkRequestCapacity`` by
    /// dropping the oldest entries.
    public func recordUnsupportedNetworkRequest(_ request: [String: Any], surfaceId: UUID) {
        var logs = unsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > Self.unsupportedNetworkRequestCapacity {
            logs.removeFirst(logs.count - Self.unsupportedNetworkRequestCapacity)
        }
        unsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    /// The recorded not-supported network-request log for `surfaceId` (empty when
    /// nothing has been recorded).
    public func unsupportedNetworkRequests(surfaceId: UUID) -> [[String: Any]] {
        unsupportedNetworkRequestsBySurface[surfaceId] ?? []
    }

    // MARK: - Teardown

    /// Drops every per-surface entry keyed by `surfaceId`, plus any element
    /// references that belong to it. Called on surface teardown.
    public func removeSurface(_ surfaceId: UUID) {
        frameSelectorBySurface.removeValue(forKey: surfaceId)
        initScriptsBySurface.removeValue(forKey: surfaceId)
        initStylesBySurface.removeValue(forKey: surfaceId)
        dialogQueueBySurface.removeValue(forKey: surfaceId)
        downloadEventsBySurface.removeValue(forKey: surfaceId)
        unsupportedNetworkRequestsBySurface.removeValue(forKey: surfaceId)
        elementRefs = elementRefs.filter { $0.value.surfaceId != surfaceId }
    }
}
