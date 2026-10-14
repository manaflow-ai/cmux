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
    private let shownAt: Date
    private var step: CloudWelcomeStep
    private(set) var isClosed = false

    init(
        trigger: CloudWelcomeTrigger,
        step: CloudWelcomeNextStep,
        analytics: ProductAnalytics,
        now: @escaping @MainActor () -> Date
    ) {
        self.trigger = trigger
        self.analytics = analytics
        self.now = now
        self.shownAt = now()
        self.step = Self.step(step)
        analytics.track(.cloudWelcomeShown(trigger: trigger, step: self.step))
        if step == .upgrade {
            analytics.track(.upgradeShown(.cloudWelcome))
        }
    }

    /// A button closed the card; `step` is the step the card offered when clicked.
    func clicked(_ button: CloudWelcomeButton, step: CloudWelcomeNextStep?) {
        guard !isClosed else { return }
        if let step { self.step = Self.step(step) }
        analytics.track(.cloudWelcomeButtonClicked(trigger: trigger, step: self.step, button: button))
        close(.init(button: button))
    }

    /// The window closed with no button.
    func windowClosed() {
        close(.windowClosed)
    }

    private func close(_ outcome: CloudWelcomeOutcome) {
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
