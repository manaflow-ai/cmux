import Foundation

struct MobilePushMutationResult: Sendable, Equatable {
    let outcome: MobilePushMutationOutcome
    let succeeded: Bool
}
