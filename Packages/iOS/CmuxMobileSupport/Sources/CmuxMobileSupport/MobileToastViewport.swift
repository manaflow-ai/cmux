import SwiftUI

#if canImport(Accessibility)
import Accessibility
#endif

struct MobileToastViewport: View {
    let presenter: MobileToastPresenter
    let clock: any Clock<Duration>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var currentID: MobileToast.ID? {
        presenter.currentPresentation?.toast.id
    }

    private var feedbackTrigger: MobileToastFeedbackTrigger? {
        guard let toast = presenter.currentPresentation?.toast,
              let feedback = toast.feedback
        else { return nil }
        return MobileToastFeedbackTrigger(id: toast.id, feedback: feedback)
    }

    @ViewBuilder
    var body: some View {
        #if os(iOS)
        toastStack
            .sensoryFeedback(trigger: feedbackTrigger) { _, newValue in
                newValue?.sensoryFeedback
            }
        #else
        toastStack
        #endif
    }

    private var toastStack: some View {
        ZStack(alignment: .top) {
            if let presentation = presenter.currentPresentation {
                MobileToastCard(
                    toast: presentation.toast,
                    dismiss: {
                        presenter.dismiss(id: presentation.toast.id, reason: .user)
                    },
                    performAction: {
                        presenter.performAction(id: presentation.toast.id)
                    }
                )
                .id(presentation.toast.id)
                .transition(reduceMotion ? .opacity : .mobileToast)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.26), value: currentID)
        .task(id: currentID) {
            guard let presentation = presenter.currentPresentation,
                  let duration = presentation.toast.lifetime.duration(
                    voiceOverEnabled: voiceOverEnabled
                  )
            else { return }

            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            presenter.dismiss(id: presentation.toast.id, reason: .timedOut)
        }
        .onChange(of: currentID) { _, newID in
            guard newID != nil,
                  voiceOverEnabled,
                  let toast = presenter.currentPresentation?.toast
            else { return }
            #if canImport(Accessibility)
            AccessibilityNotification.Announcement(toast.content.announcement).post()
            #endif
        }
    }
}
