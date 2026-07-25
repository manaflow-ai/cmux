struct ConversationTailSettlePolicy: Equatable, Sendable {
    struct State: Equatable, Sendable {
        private let requiredBottomConfirmations: Int
        private var remainingPasses: Int
        private var bottomConfirmations = 0

        init(maximumPasses: Int, requiredBottomConfirmations: Int) {
            remainingPasses = max(0, maximumPasses)
            self.requiredBottomConfirmations = max(1, requiredBottomConfirmations)
        }

        mutating func observe(isAtBottom: Bool) -> Decision {
            if isAtBottom {
                bottomConfirmations += 1
            } else {
                bottomConfirmations = 0
            }

            if bottomConfirmations >= requiredBottomConfirmations {
                return .finishedAtBottom
            }

            guard remainingPasses > 0 else {
                return isAtBottom ? .finishedAtBottom : .expiredAwayFromBottom
            }

            remainingPasses -= 1
            return .continueSettling
        }
    }

    enum Decision: Equatable, Sendable {
        case continueSettling
        case finishedAtBottom
        case expiredAwayFromBottom
    }

    private let maximumPasses: Int
    private let requiredBottomConfirmations: Int

    init(maximumPasses: Int = 32, requiredBottomConfirmations: Int = 2) {
        self.maximumPasses = maximumPasses
        self.requiredBottomConfirmations = requiredBottomConfirmations
    }

    func makeState() -> State {
        State(
            maximumPasses: maximumPasses,
            requiredBottomConfirmations: requiredBottomConfirmations
        )
    }
}
