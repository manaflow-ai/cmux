import Foundation
@testable import CmuxNextPalette
import Testing

/// The palette test support for every suite that ranks (cx-6so.52 follow-up). `palette-ranker.js`
/// is build output (scripts/cmux-next/build-palette-ranker.sh, run by
/// scripts/ci/ensure-web-bundles.sh). Without it every palette page ranks to no rows, so a plain
/// `swift test` on a tree without the bundles failed as dozens of empty-row expectations across
/// suites, which read like shared state leaking between them. A suite marked `.paletteRanker` fails
/// each test at once with one message instead and does not run its body.
nonisolated struct PaletteRankerRequired: SuiteTrait, TestTrait, TestScoping {
    static let missing = "palette-ranker.js missing: run scripts/ci/ensure-web-bundles.sh"
    /// Loaded once per test process: one JavaScriptCore context, not one per test.
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
