import Testing
@testable import CmuxCommandPalette

@Suite("Command palette usage recording policy")
struct CommandPaletteUsageRecordingPolicyTests {
    @Test func recordsAcceptedInteractiveActivations() {
        let acceptedResults: [CmuxActionExecutionResult] = [
            .completed,
            .queued,
            .dispatched,
            .presented,
        ]

        for result in acceptedResults {
            #expect(CommandPaletteUsageRecordingPolicy.shouldRecord(
                source: .commandPalette,
                result: result
            ))
        }
    }

    @Test func doesNotRecordRejectedInteractiveActivations() {
        let rejectedResults: [CmuxActionExecutionResult] = [
            .requiresArguments([]),
            .invalidArguments(["unknown"]),
            .invalidArgumentValues(["enabled"]),
            .failed(code: "unavailable", message: "Unavailable"),
        ]

        for result in rejectedResults {
            #expect(!CommandPaletteUsageRecordingPolicy.shouldRecord(
                source: .commandPalette,
                result: result
            ))
        }
    }

    @Test func automationNeverAffectsInteractiveUsageHistory() {
        let allResults: [CmuxActionExecutionResult] = [
            .completed,
            .queued,
            .dispatched,
            .presented,
            .requiresArguments([]),
            .invalidArguments(["unknown"]),
            .invalidArgumentValues(["enabled"]),
            .failed(code: "unavailable", message: "Unavailable"),
        ]

        for result in allResults {
            #expect(!CommandPaletteUsageRecordingPolicy.shouldRecord(
                source: .automation,
                result: result
            ))
        }
    }
}
