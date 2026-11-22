import Foundation

/// What a variant reads and calls: the flow model and the footer actions.
@MainActor
public struct OnboardingStepContext {
    public let model: OnboardingModel

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var index: Int { model.index }
    public var count: Int { model.steps.count }
    public var isFirst: Bool { model.isFirst }
    public var isLast: Bool { model.isLast }
    public func next() { model.next() }
    public func skip() { model.skipStep() }
    public func back() { model.back() }
    /// The services (accounts view, default apps, system settings links).
    public var services: any OnboardingServices { model.services }
}
