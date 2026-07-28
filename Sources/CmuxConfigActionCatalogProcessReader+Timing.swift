import Foundation

extension CmuxConfigActionCatalogProcessReader {
    struct Timing: Sendable {
        let sleep: @Sendable (Duration) async throws -> Void

        static let continuous = Timing { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    }
}
