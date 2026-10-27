public import CmuxNextWakeups
import Foundation

/// What a screen reads and calls: the window's model and the footer actions.
@MainActor
public struct OnboardingStepContext {
    public let model: OnboardingModel
    /// The app's one main-thread scheduler: the screens draw the model at its frames.
    public let mainWork: MainWorkScheduler

    public init(model: OnboardingModel, mainWork: MainWorkScheduler) {
        self.model = model
        self.mainWork = mainWork
    }

    public func next() { model.next() }
    public func skip() { model.skipStep() }
    public func back() { model.goBack() }
}
