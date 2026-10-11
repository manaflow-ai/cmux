public import Foundation

/// A browser pane's page state across a web view discard.
///
/// While the page is live it collects what WebKit's session state leaves
/// out: unsaved form input, whether any history entry was a form submission,
/// and a snapshot taken when the pane is hidden. A discard folds these into
/// one ``BrowserPageStateCapture``. The capture lives until the replacement
/// web view commits a document. If that commit is the restore, the capture's
/// form input waits for the load to finish; any other commit drops it.
@MainActor
public final class BrowserPageRestorationState {
    /// How a discarded page was brought back.
    public enum RestoreMethod: Equatable, Sendable {
        /// WebKit session state was assigned to the replacement web view.
        case interactionState
        /// The restore URL was loaded again.
        case urlReplay
    }

    /// A commit that completed the restore of a discarded page.
    public struct RestoredCommit: Equatable, Sendable {
        public var method: RestoreMethod
        /// Whether the restored back/forward list is the pane's whole history.
        public var coversNavigationHistory: Bool

        public init(method: RestoreMethod, coversNavigationHistory: Bool) {
            self.method = method
            self.coversNavigationHistory = coversNavigationHistory
        }
    }

    /// Unsaved input the current document last reported, or nil when none.
    public private(set) var liveFormState: BrowserFormStateSnapshot?
    /// Whether the current web view's back/forward list holds a form
    /// submission. Sticky until the list is replaced.
    public private(set) var liveContainsFormSubmission = false
    /// Whether the current document, or one of its frames, came from a form
    /// submission.
    private var liveDocumentHasFormSubmission = false
    /// Whether the main-frame navigation that has not committed yet submits
    /// a form. A redirect re-decides it.
    private var pendingDocumentHasFormSubmission = false
    /// State captured at the last discard, until a document commits.
    public private(set) var discardedCapture: BrowserPageStateCapture?
    /// The restore issued for ``discardedCapture`` that has not committed.
    public private(set) var inFlightRestore: RestoreMethod?
    /// Form input to apply once the restored document finishes loading.
    public private(set) var pendingFormRestore: BrowserFormStateSnapshot?

    private var hiddenSnapshotToken: UUID?
    private var hiddenSnapshot: BrowserPageSnapshotImage?

    /// Script message handler registered for the current web view.
    public var formStateMessageHandler: BrowserFormStateMessageHandler?
    /// Snapshot painted over the replacement web view while it restores.
    public var overlayView: BrowserPageSnapshotOverlayView?

    public init() {}

    // MARK: Live page

    public func recordLiveFormState(_ snapshot: BrowserFormStateSnapshot) {
        liveFormState = snapshot.isEmpty && !snapshot.hasUnrestorableInput ? nil : snapshot
    }

    /// Whether the current document holds typed input a restore would lose.
    public var hasUnrestorableLiveInput: Bool {
        liveFormState?.hasUnrestorableInput ?? false
    }

    /// Call for every navigation request allowed in this web view, including
    /// each redirect. WebKit keeps a form submission's request body in the
    /// entry's session state.
    ///
    /// - Parameters:
    ///   - targetFrameIsMainFrame: Whether the request loads in the main frame
    ///     or a subframe, or nil when it has no target frame. Such a request
    ///     opens a new window, so it is ignored.
    ///   - isFormSubmission: Whether the request sends a body, such as a POST.
    public func noteNavigationRequest(targetFrameIsMainFrame: Bool?, isFormSubmission: Bool) {
        guard let isMainFrame = targetFrameIsMainFrame else { return }
        if isFormSubmission {
            liveContainsFormSubmission = true
        }
        if isMainFrame {
            pendingDocumentHasFormSubmission = isFormSubmission
        } else if isFormSubmission {
            liveDocumentHasFormSubmission = true
        }
    }

    // MARK: Hidden snapshot

    /// Starts a snapshot for a pane that was just hidden and returns the
    /// token its completion must present.
    public func beginHiddenSnapshot() -> UUID {
        let token = UUID()
        hiddenSnapshotToken = token
        hiddenSnapshot = nil
        return token
    }

    /// Stores a finished snapshot. A snapshot that completes after the pane
    /// was discarded still attaches to that discard's capture.
    public func completeHiddenSnapshot(token: UUID, image: BrowserPageSnapshotImage?) {
        guard let image else { return }
        if hiddenSnapshotToken == token {
            hiddenSnapshot = image
        } else if var capture = discardedCapture, capture.snapshotToken == token, capture.snapshot == nil {
            capture.snapshot = image
            discardedCapture = capture
        }
    }

    /// Forgets the hidden snapshot, for a pane shown again before a discard.
    public func cancelHiddenSnapshot() {
        hiddenSnapshotToken = nil
        hiddenSnapshot = nil
    }

    // MARK: Discard and restore

    /// Folds the live state into a capture as the web view is dropped.
    ///
    /// - Parameters:
    ///   - interactionState: The dropped web view's session state, when it
    ///     showed a replayable page.
    ///   - documentURL: URL of that web view's current history entry.
    ///   - anchorURL: The URL the pane will restore to.
    ///   - coversNavigationHistory: Whether the native back/forward list was
    ///     the pane's history.
    public func recordDiscard(
        interactionState: Data?,
        documentURL: URL?,
        anchorURL: URL?,
        coversNavigationHistory: Bool
    ) {
        defer {
            liveFormState = nil
            liveContainsFormSubmission = false
            liveDocumentHasFormSubmission = false
            pendingDocumentHasFormSubmission = false
            cancelHiddenSnapshot()
            inFlightRestore = nil
            pendingFormRestore = nil
        }
        // A web view dropped before its restore committed holds nothing newer
        // than the capture it was restoring.
        guard discardedCapture == nil else { return }
        let formState = liveFormState.flatMap { $0.sharesOrigin(with: documentURL) ? $0 : nil }
        discardedCapture = BrowserPageStateCapture(
            interactionState: interactionState,
            documentURL: documentURL,
            anchorURL: anchorURL,
            formState: formState,
            snapshot: hiddenSnapshot,
            snapshotToken: hiddenSnapshotToken,
            coversNavigationHistory: coversNavigationHistory,
            containsFormSubmission: liveContainsFormSubmission,
            documentHasFormSubmission: liveDocumentHasFormSubmission
        )
    }

    /// Seeds the capture from session state saved by a previous launch. Such
    /// state was only saved when it covered the pane's history and held no
    /// form submission.
    public func seedFromSessionState(_ interactionState: Data, documentURL: URL?, anchorURL: URL?) {
        guard !interactionState.isEmpty else { return }
        discardedCapture = BrowserPageStateCapture(
            interactionState: interactionState,
            documentURL: documentURL,
            anchorURL: anchorURL,
            coversNavigationHistory: true,
            containsFormSubmission: false
        )
    }

    /// Call when any main-frame navigation starts. The restore recorded after
    /// this call is the one in flight; any later navigation supersedes it, so
    /// its commit does not bring back the capture's input.
    public func noteNavigationStarted() {
        inFlightRestore = nil
    }

    /// Records the restore issued for the discarded capture.
    public func noteRestoreStarted(_ method: RestoreMethod) {
        guard discardedCapture != nil else { return }
        inFlightRestore = method
    }

    /// Drops the capture so the next restore reloads from the network, for
    /// an explicit reload.
    public func dropCapture() {
        discardedCapture = nil
        inFlightRestore = nil
        pendingFormRestore = nil
    }

    /// Drops the capture for a pane brought back without a restore, such as
    /// by a history navigation.
    ///
    /// - Returns: Whether the web view's back/forward list already holds the
    ///   pane's whole history because session state was assigned to it.
    @discardableResult
    public func noteReactivatedWithoutRestore() -> Bool {
        let restoredHistory = inFlightRestore == .interactionState
            && discardedCapture?.coversNavigationHistory == true
        dropCapture()
        return restoredHistory
    }

    /// Call for every main-frame document commit except the browser's own
    /// error page, which keeps the capture for the next restore attempt.
    ///
    /// - Parameter isDiscardRestoreCommit: Whether the commit is the discarded
    ///   page coming back rather than a navigation somewhere else.
    /// - Returns: The restore the commit completed, or nil when it completed
    ///   none.
    @discardableResult
    public func noteDocumentCommitted(isDiscardRestoreCommit: Bool) -> RestoredCommit? {
        liveDocumentHasFormSubmission = pendingDocumentHasFormSubmission
        pendingDocumentHasFormSubmission = false
        liveFormState = nil
        pendingFormRestore = nil
        let method = inFlightRestore
        inFlightRestore = nil
        guard let capture = discardedCapture else { return nil }
        discardedCapture = nil
        guard isDiscardRestoreCommit, let method else { return nil }
        if method == .interactionState {
            liveContainsFormSubmission = capture.containsFormSubmission
        }
        pendingFormRestore = capture.formState
        return RestoredCommit(method: method, coversNavigationHistory: capture.coversNavigationHistory)
    }

    /// Returns and clears form input waiting for the document at `url`.
    /// Input is never applied to another origin.
    public func takePendingFormRestore(for url: URL?) -> BrowserFormStateSnapshot? {
        defer { pendingFormRestore = nil }
        guard let pendingFormRestore, !pendingFormRestore.isEmpty, pendingFormRestore.sharesOrigin(with: url) else {
            return nil
        }
        return pendingFormRestore
    }

    /// Puts a failed form restore back so a later document milestone can retry it.
    public func retryPendingFormRestore(_ snapshot: BrowserFormStateSnapshot) {
        pendingFormRestore = snapshot
    }

    /// Session state that may be written to the session file for a pane whose
    /// web view is discarded, or nil when the capture may not be persisted.
    public func persistableDiscardedInteractionState() -> Data? {
        discardedCapture?.persistableInteractionState()
    }

    /// Removes the restore overlay, if one is showing.
    public func dismissOverlay() {
        overlayView?.dismiss()
        overlayView = nil
    }
}
