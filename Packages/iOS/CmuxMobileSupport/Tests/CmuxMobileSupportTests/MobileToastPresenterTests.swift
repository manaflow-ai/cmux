import Testing
@testable import CmuxMobileSupport

@Suite("Mobile toast presenter")
struct MobileToastPresenterTests {
    @Test func semanticFactoriesKeepCompositionsConsistent() {
        let success = MobileToast.success(.verbatim("Saved"))
        let error = MobileToast.error(title: .verbatim("Save failed"))
        let progress = MobileToast.progress(title: .verbatim("Saving"))

        #expect(success.content.isCompact)
        #expect(success.tone == .success)
        #expect(success.lifetime == .brief)
        #expect(!error.content.isCompact)
        #expect(error.tone == .error)
        #expect(error.lifetime == .standard)
        #expect(progress.content.isProgress)
        #expect(progress.lifetime == .persistent)
    }

    @Test func voiceOverExtendsTransientLifetimes() {
        #expect(MobileToastLifetime.brief.duration(voiceOverEnabled: false) == .milliseconds(2_800))
        #expect(MobileToastLifetime.brief.duration(voiceOverEnabled: true) == .milliseconds(5_600))
        #expect(MobileToastLifetime.persistent.duration(voiceOverEnabled: true) == nil)
    }

    @Test @MainActor func firstToastBecomesCurrent() {
        let presenter = MobileToastPresenter()
        let toast = MobileToast.information(.verbatim("Connected"))

        presenter.present(toast)

        #expect(presenter.currentPresentation?.toast.id == toast.id)
        #expect(presenter.queuedCount == 0)
    }

    @Test @MainActor func higherPriorityToastSupersedesCurrentToast() {
        let presenter = MobileToastPresenter()
        let recorder = DismissalRecorder()
        let information = MobileToast.information(.verbatim("Connected"))
        let error = MobileToast.error(title: .verbatim("Connection lost"))
        presenter.present(information) { recorder.reasons.append($0) }

        presenter.present(error)

        #expect(presenter.currentPresentation?.toast.id == error.id)
        #expect(recorder.reasons == [.replaced])
    }

    @Test @MainActor func equalPriorityToastWaitsAndPromotesAfterDismissal() {
        let presenter = MobileToastPresenter()
        let first = MobileToast.information(.verbatim("One"))
        let second = MobileToast.success(.verbatim("Two"))
        presenter.present(first)
        presenter.present(second)

        presenter.dismiss(id: first.id, reason: .user)

        #expect(presenter.currentPresentation?.toast.id == second.id)
        #expect(presenter.queuedCount == 0)
    }

    @Test @MainActor func matchingCurrentKeyCoalescesRepeatedEvents() {
        let presenter = MobileToastPresenter()
        let recorder = DismissalRecorder()
        let first = MobileToast.information(.verbatim("First"), coalescingKey: "sync")
        let replacement = MobileToast.information(.verbatim("Latest"), coalescingKey: "sync")
        presenter.present(first) { recorder.reasons.append($0) }

        presenter.present(replacement)

        #expect(presenter.currentPresentation?.toast.id == replacement.id)
        #expect(presenter.queuedCount == 0)
        #expect(recorder.reasons == [.replaced])
    }

    @Test @MainActor func matchingQueuedKeyReplacesInPlace() {
        let presenter = MobileToastPresenter()
        let recorder = DismissalRecorder()
        let current = MobileToast.error(title: .verbatim("Current"))
        let queued = MobileToast.information(.verbatim("Old"), coalescingKey: "status")
        let replacement = MobileToast.success(.verbatim("New"), coalescingKey: "status")
        presenter.present(current)
        presenter.present(queued) { recorder.reasons.append($0) }

        presenter.present(replacement)

        #expect(presenter.currentPresentation?.toast.id == current.id)
        #expect(presenter.queuedToasts.map(\.id) == [replacement.id])
        #expect(recorder.reasons == [.replaced])
    }

    @Test @MainActor func boundedQueueDropsOldestWaitingToast() {
        let presenter = MobileToastPresenter(maximumQueueDepth: 2)
        let recorder = DismissalRecorder()
        let current = MobileToast.error(title: .verbatim("Current"))
        let oldest = MobileToast.information(.verbatim("Oldest"))
        let middle = MobileToast.information(.verbatim("Middle"))
        let newest = MobileToast.information(.verbatim("Newest"))
        presenter.present(current)
        presenter.present(oldest) { recorder.reasons.append($0) }
        presenter.present(middle)

        presenter.present(newest)

        #expect(presenter.queuedToasts.map(\.id) == [middle.id, newest.id])
        #expect(recorder.reasons == [.replaced])
    }

    @Test @MainActor func staleDismissalCannotRemoveReplacement() {
        let presenter = MobileToastPresenter()
        let old = MobileToast.information(.verbatim("Old"), coalescingKey: "event")
        let replacement = MobileToast.information(.verbatim("New"), coalescingKey: "event")
        presenter.present(old)
        presenter.present(replacement)

        presenter.dismiss(id: old.id, reason: .timedOut)

        #expect(presenter.currentPresentation?.toast.id == replacement.id)
    }

    @Test @MainActor func actionRunsBeforeItsToastDismisses() {
        let presenter = MobileToastPresenter()
        let recorder = DismissalRecorder()
        let toast = MobileToast.notice(
            title: .verbatim("Update available"),
            action: MobileToastAction(label: .verbatim("Open")) {
                recorder.actionSawVisibleToast = presenter.currentPresentation != nil
            }
        )
        presenter.present(toast) { recorder.reasons.append($0) }

        presenter.performAction(id: toast.id)

        #expect(recorder.actionSawVisibleToast)
        #expect(recorder.reasons == [.action])
        #expect(presenter.currentPresentation == nil)
    }

    @Test @MainActor func dismissingKeyRemovesVisibleAndQueuedMatches() {
        let presenter = MobileToastPresenter()
        let recorder = DismissalRecorder()
        let current = MobileToast.information(.verbatim("Current"), coalescingKey: "sync")
        let unrelated = MobileToast.information(.verbatim("Unrelated"), coalescingKey: "other")
        presenter.present(current) { recorder.reasons.append($0) }
        presenter.present(unrelated)

        presenter.dismiss(coalescingKey: "sync")

        #expect(presenter.currentPresentation?.toast.id == unrelated.id)
        #expect(recorder.reasons == [.programmatic])
    }

    @Test @MainActor func dismissalCallbackCannotAccidentallyRemoveReentrantToast() {
        let presenter = MobileToastPresenter()
        let current = MobileToast.information(.verbatim("Current"), coalescingKey: "sync")
        let replacement = MobileToast.information(.verbatim("Replacement"), coalescingKey: "sync")
        presenter.present(current) { _ in presenter.present(replacement) }

        presenter.dismiss(coalescingKey: "sync")

        #expect(presenter.currentPresentation?.toast.id == replacement.id)
    }
}

@MainActor
private final class DismissalRecorder {
    var reasons: [MobileToastDismissReason] = []
    var actionSawVisibleToast = false
}
