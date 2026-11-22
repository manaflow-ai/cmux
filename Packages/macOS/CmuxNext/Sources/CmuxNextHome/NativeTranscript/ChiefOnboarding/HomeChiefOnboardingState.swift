public import CmuxNextHomeModel

/// What Meet Chief's card shows (``HomeNativeTranscriptView/showChiefOnboarding(_:)``): a value copy of
/// ``ChiefOnboarding``, so the card holds no reference to the model (the Home's snapshot boundary).
public struct HomeChiefOnboardingState: Sendable, Equatable {
    /// The step on screen.
    public var step: ChiefOnboardingStep
    /// The step's place, from 0.
    public var index: Int
    /// How many steps there are.
    public var count: Int
    /// The mode the access step shows.
    public var mode: ChiefPermissionMode
    /// Whether the person may change the mode here.
    public var canChooseMode: Bool
    /// An administrator sets the mode (the access step says so instead of offering the choice).
    public var modeManaged: Bool
    /// The density the look step shows (nil: one it does not offer).
    public var density: ChiefOnboardingDensity?
    /// The text size in points, and whether it can go one point smaller and larger.
    public var textSize: Double
    public var canShrinkText: Bool
    public var canGrowText: Bool
    /// The last change did not save.
    public var writeFailed: Bool

    public init(step: ChiefOnboardingStep, index: Int, count: Int, mode: ChiefPermissionMode, canChooseMode: Bool,
                modeManaged: Bool, density: ChiefOnboardingDensity?, textSize: Double, canShrinkText: Bool,
                canGrowText: Bool, writeFailed: Bool) {
        self.step = step
        self.index = index
        self.count = count
        self.mode = mode
        self.canChooseMode = canChooseMode
        self.modeManaged = modeManaged
        self.density = density
        self.textSize = textSize
        self.canShrinkText = canShrinkText
        self.canGrowText = canGrowText
        self.writeFailed = writeFailed
    }

    /// The card's state for `onboarding` now; nil while it does not show. Read inside observation, it follows
    /// every change the card draws (the step, a pick, a setting changed elsewhere).
    /// - Parameter onboarding: The app's Meet Chief.
    @MainActor
    public init?(_ onboarding: ChiefOnboarding) {
        guard onboarding.shows else { return nil }
        self.init(step: onboarding.step, index: onboarding.index, count: onboarding.steps.count, mode: onboarding.mode,
                  canChooseMode: onboarding.canChooseMode, modeManaged: onboarding.modeManaged, density: onboarding.density,
                  textSize: onboarding.textSize, canShrinkText: onboarding.canShrinkText, canGrowText: onboarding.canGrowText,
                  writeFailed: onboarding.writeFailed)
    }

    /// Whether Back shows.
    public var canGoBack: Bool { index > 0 }
    /// Whether the primary button ends it (Start chatting).
    public var isLast: Bool { index == count - 1 }
}
