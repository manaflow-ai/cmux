import Testing
@testable import CmuxNextBrowser

/// Which document a page shows: one a form submission (POST) produced must
/// never be loaded again without the user (hibernation wake, duplication).
struct FormSubmissionTrackerTests {
    @Test func aCommittedPostMarksTheDocument() {
        var tracker = FormSubmissionTracker()
        tracker.decided(method: "POST", isMainFrame: true)
        #expect(!tracker.showsFormSubmission, "not until the document commits")
        tracker.committed()
        #expect(tracker.showsFormSubmission)
    }

    @Test func aLaterGetClearsIt() {
        var tracker = FormSubmissionTracker()
        tracker.decided(method: "POST", isMainFrame: true)
        tracker.committed()
        tracker.decided(method: "GET", isMainFrame: true)
        tracker.committed()
        #expect(!tracker.showsFormSubmission)
    }

    @Test func subframeAndCancelledPostsDoNotCount() {
        var tracker = FormSubmissionTracker()
        tracker.decided(method: "POST", isMainFrame: false)
        tracker.committed()
        #expect(!tracker.showsFormSubmission)
        tracker.decided(method: "post", isMainFrame: true)
        tracker.cancelled()
        tracker.committed()
        #expect(!tracker.showsFormSubmission, "a cancelled POST never committed")
    }

    @Test func methodsCompareWithoutCase() {
        var tracker = FormSubmissionTracker()
        tracker.decided(method: "post", isMainFrame: true)
        tracker.committed()
        #expect(tracker.showsFormSubmission)
    }
}
