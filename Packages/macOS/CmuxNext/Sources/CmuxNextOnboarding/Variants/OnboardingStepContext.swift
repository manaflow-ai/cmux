import Foundation

/// What a screen reads and calls: the window's model and the footer actions.
@MainActor
public struct OnboardingStepContext {
    public let model: OnboardingModel

    public init(model: OnboardingModel) {
        self.model = model
    }

    public func next() { model.next() }
    public func skip() { model.skipStep() }
}
