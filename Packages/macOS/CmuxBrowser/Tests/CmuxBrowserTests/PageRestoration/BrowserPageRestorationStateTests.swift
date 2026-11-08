import CoreGraphics
import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
struct BrowserPageRestorationStateTests {
    private let pageURL = URL(string: "https://example.com/compose")!
    private let sessionState = Data([0x0A, 0x0B])

    private func form(_ url: URL, value: String = "draft") -> BrowserFormStateSnapshot {
        BrowserFormStateSnapshot(documentURL: url, fields: [.init(key: "id:body", value: value)])
    }

    private func image(_ byte: UInt8) -> BrowserPageSnapshotImage {
        BrowserPageSnapshotImage(jpegData: Data([byte]), pointSize: CGSize(width: 10, height: 20))
    }

    private func discard(_ restoration: BrowserPageRestorationState, covers: Bool = true) {
        restoration.recordDiscard(
            interactionState: sessionState,
            documentURL: pageURL,
            anchorURL: pageURL,
            coversNavigationHistory: covers
        )
    }

    @Test("A discard captures form input, snapshot and taint, and clears live state")
    func discardCapturesLiveState() throws {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        let token = restoration.beginHiddenSnapshot()
        restoration.completeHiddenSnapshot(token: token, image: image(1))

        discard(restoration)

        let capture = try #require(restoration.discardedCapture)
        #expect(capture.interactionState == sessionState)
        #expect(capture.anchorURL == pageURL)
        #expect(capture.formState == form(pageURL))
        #expect(capture.snapshot == image(1))
        #expect(capture.containsFormSubmission)
        #expect(restoration.liveFormState == nil)
        #expect(!restoration.liveContainsFormSubmission)
    }

    @Test("Input reported for another origin is not captured")
    func discardDropsForeignInput() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(URL(string: "https://other.example/")!))
        discard(restoration)
        #expect(restoration.discardedCapture?.formState == nil)
    }

    @Test("An empty report clears earlier input")
    func emptyReportClearsInput() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        restoration.recordLiveFormState(BrowserFormStateSnapshot(documentURL: pageURL, fields: []))
        #expect(restoration.liveFormState == nil)
    }

    @Test("A report of only unrestorable input is kept until the page clears it")
    func unrestorableOnlyReportIsKept() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(BrowserFormStateSnapshot(documentURL: pageURL, fields: [], hasUnrestorableInput: true))
        #expect(restoration.hasUnrestorableLiveInput)

        restoration.recordLiveFormState(BrowserFormStateSnapshot(documentURL: pageURL, fields: []))
        #expect(!restoration.hasUnrestorableLiveInput)
        #expect(restoration.liveFormState == nil)
    }

    @Test("A new document forgets the previous document's unrestorable input")
    func commitClearsUnrestorableInput() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(BrowserFormStateSnapshot(documentURL: pageURL, fields: [], hasUnrestorableInput: true))
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        #expect(!restoration.hasUnrestorableLiveInput)
    }

    @Test("A snapshot finishing after the discard attaches to its capture")
    func lateSnapshotAttaches() {
        let restoration = BrowserPageRestorationState()
        let token = restoration.beginHiddenSnapshot()
        discard(restoration)
        #expect(restoration.discardedCapture?.snapshot == nil)

        restoration.completeHiddenSnapshot(token: UUID(), image: image(9))
        #expect(restoration.discardedCapture?.snapshot == nil)
        restoration.completeHiddenSnapshot(token: token, image: image(2))
        #expect(restoration.discardedCapture?.snapshot == image(2))
    }

    @Test("A snapshot for a pane shown again is dropped")
    func cancelledSnapshotIsDropped() {
        let restoration = BrowserPageRestorationState()
        let token = restoration.beginHiddenSnapshot()
        restoration.cancelHiddenSnapshot()
        restoration.completeHiddenSnapshot(token: token, image: image(3))
        discard(restoration)
        #expect(restoration.discardedCapture?.snapshot == nil)
    }

    @Test("Discarding a web view whose restore never committed keeps the first capture")
    func secondDiscardKeepsFirstCapture() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        discard(restoration)
        restoration.noteRestoreStarted(.interactionState)

        restoration.recordDiscard(
            interactionState: nil,
            documentURL: nil,
            anchorURL: pageURL,
            coversNavigationHistory: false
        )

        #expect(restoration.discardedCapture?.interactionState == sessionState)
        #expect(restoration.discardedCapture?.formState == form(pageURL))
        #expect(restoration.inFlightRestore == nil)
    }

    @Test("A session-state restore commit brings back input and the form-submission taint")
    func interactionStateCommit() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        discard(restoration)
        restoration.noteRestoreStarted(.interactionState)

        let commit = restoration.noteDocumentCommitted(isDiscardRestoreCommit: true)

        #expect(commit == .init(method: .interactionState, coversNavigationHistory: true))
        #expect(restoration.discardedCapture == nil)
        #expect(restoration.liveContainsFormSubmission)
        #expect(restoration.takePendingFormRestore(for: pageURL) == form(pageURL))
        #expect(restoration.takePendingFormRestore(for: pageURL) == nil)
    }

    @Test("A URL replay commit starts a fresh history without the taint")
    func urlReplayCommit() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        discard(restoration, covers: false)
        restoration.noteRestoreStarted(.urlReplay)

        let commit = restoration.noteDocumentCommitted(isDiscardRestoreCommit: true)

        #expect(commit == .init(method: .urlReplay, coversNavigationHistory: false))
        #expect(!restoration.liveContainsFormSubmission)
        #expect(restoration.takePendingFormRestore(for: pageURL) == form(pageURL))
    }

    @Test("A commit elsewhere drops the capture and its input")
    func unrelatedCommitDropsCapture() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        discard(restoration)
        restoration.noteRestoreStarted(.interactionState)

        #expect(restoration.noteDocumentCommitted(isDiscardRestoreCommit: false) == nil)
        #expect(restoration.discardedCapture == nil)
        #expect(restoration.takePendingFormRestore(for: pageURL) == nil)
    }

    @Test("Pending input is never applied to another origin")
    func pendingInputStaysOnOrigin() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        discard(restoration)
        restoration.noteRestoreStarted(.urlReplay)
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: true)

        #expect(restoration.takePendingFormRestore(for: URL(string: "https://login.example/")) == nil)
        #expect(restoration.takePendingFormRestore(for: pageURL) == nil)
    }

    @Test("An explicit reload drops the capture")
    func dropCapture() {
        let restoration = BrowserPageRestorationState()
        discard(restoration)
        restoration.noteRestoreStarted(.interactionState)
        restoration.dropCapture()
        #expect(restoration.discardedCapture == nil)
        #expect(restoration.inFlightRestore == nil)
        restoration.noteRestoreStarted(.urlReplay)
        #expect(restoration.inFlightRestore == nil)
    }

    @Test("Saved session state seeds a persistable capture")
    func seedFromSessionState() {
        let restoration = BrowserPageRestorationState()
        restoration.seedFromSessionState(sessionState, documentURL: pageURL, anchorURL: pageURL)
        #expect(restoration.discardedCapture?.anchorURL == pageURL)
        #expect(restoration.persistableDiscardedInteractionState() == sessionState)

        let empty = BrowserPageRestorationState()
        empty.seedFromSessionState(Data(), documentURL: pageURL, anchorURL: pageURL)
        #expect(empty.discardedCapture == nil)
    }

    @Test("A tainted capture is not persisted")
    func taintedCaptureIsNotPersisted() {
        let restoration = BrowserPageRestorationState()
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        discard(restoration)
        #expect(restoration.persistableDiscardedInteractionState() == nil)
    }

    @Test("A navigation started after the restore is not treated as the restore")
    func laterNavigationSupersedesRestore() {
        let restoration = BrowserPageRestorationState()
        restoration.recordLiveFormState(form(pageURL))
        discard(restoration)
        restoration.noteNavigationStarted()
        restoration.noteRestoreStarted(.interactionState)
        #expect(restoration.inFlightRestore == .interactionState)

        restoration.noteNavigationStarted()

        #expect(restoration.noteDocumentCommitted(isDiscardRestoreCommit: true) == nil)
        #expect(restoration.takePendingFormRestore(for: pageURL) == nil)
    }

    @Test("A page shown as a form submission result is marked in the capture")
    func submittedDocumentIsMarked() throws {
        let restoration = BrowserPageRestorationState()
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        discard(restoration)

        let capture = try #require(restoration.discardedCapture)
        #expect(capture.documentHasFormSubmission)
        #expect(capture.containsFormSubmission)
    }

    @Test("A submission redirected to a GET page leaves that page unmarked")
    func redirectedSubmissionIsNotMarked() throws {
        let restoration = BrowserPageRestorationState()
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: false)
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        discard(restoration)

        let capture = try #require(restoration.discardedCapture)
        #expect(!capture.documentHasFormSubmission)
        #expect(capture.containsFormSubmission)
    }

    @Test("A form submitted in a frame marks the page that holds the frame")
    func subframeSubmissionMarksPage() throws {
        let restoration = BrowserPageRestorationState()
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: false)
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        restoration.noteNavigationRequest(targetFrameIsMainFrame: false, isFormSubmission: false)
        restoration.noteNavigationRequest(targetFrameIsMainFrame: false, isFormSubmission: true)
        discard(restoration)

        let capture = try #require(restoration.discardedCapture)
        #expect(capture.documentHasFormSubmission)
        #expect(capture.containsFormSubmission)
    }

    @Test("A request that opens a new window leaves this pane's marks alone")
    func newWindowRequestIsIgnored() throws {
        let restoration = BrowserPageRestorationState()
        restoration.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        restoration.noteNavigationRequest(targetFrameIsMainFrame: nil, isFormSubmission: false)
        restoration.noteDocumentCommitted(isDiscardRestoreCommit: false)
        discard(restoration)
        let submitted = try #require(restoration.discardedCapture)
        #expect(submitted.documentHasFormSubmission)

        let plain = BrowserPageRestorationState()
        plain.noteNavigationRequest(targetFrameIsMainFrame: nil, isFormSubmission: true)
        plain.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: false)
        plain.noteDocumentCommitted(isDiscardRestoreCommit: false)
        discard(plain)
        let capture = try #require(plain.discardedCapture)
        #expect(!capture.documentHasFormSubmission)
        #expect(!capture.containsFormSubmission)
    }

    @Test("Only a commit moves the form submission mark to another page")
    func markFollowsCommits() throws {
        let navigatedAway = BrowserPageRestorationState()
        navigatedAway.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        navigatedAway.noteDocumentCommitted(isDiscardRestoreCommit: false)
        navigatedAway.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: false)
        navigatedAway.noteDocumentCommitted(isDiscardRestoreCommit: false)
        discard(navigatedAway)
        let away = try #require(navigatedAway.discardedCapture)
        #expect(!away.documentHasFormSubmission)
        #expect(away.containsFormSubmission)

        let stayed = BrowserPageRestorationState()
        stayed.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: true)
        stayed.noteDocumentCommitted(isDiscardRestoreCommit: false)
        stayed.noteNavigationRequest(targetFrameIsMainFrame: true, isFormSubmission: false)
        discard(stayed)
        let stay = try #require(stayed.discardedCapture)
        #expect(stay.documentHasFormSubmission)
    }

    @Test("Reactivating reports whether assigned session state holds the history")
    func reactivationReportsRestoredHistory() {
        let restoring = BrowserPageRestorationState()
        discard(restoring)
        restoring.noteRestoreStarted(.interactionState)
        #expect(restoring.noteReactivatedWithoutRestore())
        #expect(restoring.discardedCapture == nil)

        let partial = BrowserPageRestorationState()
        discard(partial, covers: false)
        partial.noteRestoreStarted(.interactionState)
        #expect(!partial.noteReactivatedWithoutRestore())

        let idle = BrowserPageRestorationState()
        discard(idle)
        #expect(!idle.noteReactivatedWithoutRestore())
        #expect(idle.discardedCapture == nil)
    }
}
