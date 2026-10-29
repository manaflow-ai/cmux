import CmuxCloud
import CmuxProductAnalytics
import Foundation

/// The analytics for one shown welcome card: shown, each button, and how it
/// closed. Exactly one `cmux_cloud_welcome_closed` per shown card.
@MainActor
final class CloudWelcomeAnalyticsSession {
    let trigger: CloudWelcomeTrigger
    private let analytics: ProductAnalytics
    private let now: @MainActor () -> Date
    /// The controller's step resolver, which the card also renders from.
    private let currentStep: @MainActor () -> CloudWelcomeNextStep
    private let shownAt: Date
    private var recordedUpgradeImpression = false
    private(set) var isClosed = false

    init(
        trigger: CloudWelcomeTrigger,
        currentStep: @escaping @MainActor () -> CloudWelcomeNextStep,
        analytics: ProductAnalytics,
        now: @escaping @MainActor () -> Date
    ) {
        self.trigger = trigger
        self.analytics = analytics
        self.now = now
        self.currentStep = currentStep
        self.shownAt = now()
        let step = currentStep()
        analytics.track(.cloudWelcomeShown(trigger: trigger, step: Self.step(step)))
        stepDisplayed(step)
    }

    /// The card now offers `step`. A plan that loads after the card opened can
    /// turn Open Cloud into Upgrade; the Upgrade impression is recorded the
    /// first time it is on screen.
    func stepDisplayed(_ step: CloudWelcomeNextStep) {
        guard step == .upgrade, !recordedUpgradeImpression, !isClosed else { return }
        recordedUpgradeImpression = true
        analytics.track(.upgradeShown(.cloudWelcome))
    }

    /// A button closed the card. `step` is the step its primary button
    /// offered; Not Now passes nil and records the step on screen now.
    func clicked(_ button: CloudWelcomeButton, step: CloudWelcomeNextStep?) {
        guard !isClosed else { return }
        let offered = Self.step(step ?? currentStep())
        analytics.track(.cloudWelcomeButtonClicked(trigger: trigger, step: offered, button: button))
        close(.init(button: button), step: offered)
    }

    /// The window closed with no button.
    func windowClosed() {
        guard !isClosed else { return }
        close(.windowClosed, step: Self.step(currentStep()))
    }

    private func close(_ outcome: CloudWelcomeOutcome, step: CloudWelcomeStep) {
        guard !isClosed else { return }
        isClosed = true
        analytics.track(.cloudWelcomeClosed(
            trigger: trigger,
            step: step,
            outcome: outcome,
            visibleFor: DurationBucket(seconds: now().timeIntervalSince(shownAt))
        ))
    }

    static func step(_ step: CloudWelcomeNextStep) -> CloudWelcomeStep {
        switch step {
        case .upgrade: .upgrade
        case .enable: .enable
        case .signIn: .signIn
        case .openCloud: .openCloud
        }
    }
}
