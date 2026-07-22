import Testing
@testable import CmuxCommandPalette

@Suite("Cmux action execution result command-palette usage")
struct CmuxActionExecutionResultCommandPaletteUsageTests {
    @Test func recordsAcceptedInteractiveActivations() {
        let acceptedResults: [CmuxActionExecutionResult] = [
            .completed,
            .queued,
            .dispatched,
            .presented,
        ]

        for result in acceptedResults {
            #expect(result.shouldRecordCommandPaletteUsage(for: .commandPalette))
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
            #expect(!result.shouldRecordCommandPaletteUsage(for: .commandPalette))
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
            #expect(!result.shouldRecordCommandPaletteUsage(for: .automation))
        }
    }
}
