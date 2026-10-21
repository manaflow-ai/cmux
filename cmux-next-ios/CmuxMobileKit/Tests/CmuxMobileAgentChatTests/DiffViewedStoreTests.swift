@testable import CmuxMobileAgentChat
import CmuxMobileDiff
import Foundation
import Testing

/// Round 3 review N1: viewed marks are one model shared by the transcript diff, the
/// Changes list and Review, and they survive relaunch.
@MainActor
@Suite struct DiffViewedStoreTests {
    private func defaults() -> UserDefaults {
        let name = "DiffViewedStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let files = [
        DiffFile(path: "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport/TransportKind.swift", oldText: nil, newText: "enum TransportKind {}\n"),
        DiffFile(path: "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTransport/LinkDialer.swift", oldText: "a\nb\n", newText: "a\nc\n"),
        DiffFile(path: "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/ConnectionSettings.swift", oldText: "x\n", newText: "y\n"),
    ]

    private var turnChanges: DiffChangeSet { DiffChangeSet(id: "turn-2", title: "Changes", subtitle: "This turn", files: files) }

    @Test func markingInTheFileScreenShowsInReviewAndAgentEdits() {
        let store = DiffViewedStore(defaults: defaults())
        // The transcript's diff opens a file screen on the turn's change set.
        let fromTranscript = DiffViewerState(changeSet: turnChanges, viewedStore: store)
        fromTranscript.toggleViewed(files[1])
        // Review (Changes) and the chat's Agent edits open their own states later.
        let review = DiffViewerState(changeSet: turnChanges, viewedStore: store)
        #expect(review.viewed.count == 1)
        #expect(review.isViewed(files[1]))
        let agentEdits = DiffViewerState(changeSet: DiffChangeSet(id: "session", title: "Agent edits", subtitle: "", files: files), viewedStore: store)
        #expect(agentEdits.viewed == [files[1].id])
        // Unmarking in Review clears it everywhere.
        review.toggleViewed(files[1])
        #expect(fromTranscript.viewed.isEmpty)
    }

    @Test func marksSurviveRelaunch() {
        let defaults = defaults()
        DiffViewedStore(defaults: defaults).setViewed(true, files[0])
        DiffViewedStore(defaults: defaults).setViewed(true, files[2])
        let relaunched = DiffViewedStore(defaults: defaults)
        #expect(relaunched.viewedIDs(in: turnChanges) == [files[0].id, files[2].id])
    }

    @Test func aLaterEditOfTheSameFileStartsUnviewed() {
        let store = DiffViewedStore(defaults: defaults())
        store.setViewed(true, files[1])
        let edited = DiffFile(path: files[1].path, oldText: "a\nc\n", newText: "a\nd\n")
        #expect(!store.isViewed(edited))
        #expect(DiffViewedStore.key(for: files[1]) == DiffViewedStore.key(for: DiffFile(path: files[1].path, oldText: "a\nb\n", newText: "a\nc\n")))
    }
}
