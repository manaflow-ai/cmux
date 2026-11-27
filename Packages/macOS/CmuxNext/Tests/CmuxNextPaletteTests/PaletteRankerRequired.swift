import Foundation
@testable import CmuxNextPalette
import Testing

/// The palette test support for every suite that ranks (cx-6so.52 follow-up). Without the shared
/// ranker every palette page ranks to no rows, which reads like dozens of empty-row expectations
/// failing across suites. A suite marked `.paletteRanker` fails each test at once with one message
/// instead and does not run its body.
nonisolated struct PaletteRankerRequired: SuiteTrait, TestTrait, TestScoping {
    static let missing = "the shared palette ranker did not load"
    /// Loaded once per test process: one ranker handle, not one per test.
    static let sharedLoadError: PaletteRankerBridgeError? = PaletteRanker().loadError

    let loadError: @Sendable () -> PaletteRankerBridgeError?

    var isRecursive: Bool { true }

    @concurrent func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        if let error = loadError() {
            Issue.record(Comment(rawValue: "\(Self.missing) (\(error.localizedDescription))"))
            return
        }
        try await function()
    }
}

extension Trait where Self == PaletteRankerRequired {
    /// The suite ranks palette rows and needs the built ranker bundle.
    static var paletteRanker: Self { PaletteRankerRequired(loadError: { PaletteRankerRequired.sharedLoadError }) }
}
