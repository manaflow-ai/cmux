import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserDesignModeScriptTests {
    @Test func loadsBundledRuntimeResource() async throws {
        let source = try await BrowserDesignModeScript().source()

        #expect(!source.isEmpty)
    }

    @Test func missingRuntimeResourceThrowsWithoutTerminatingProcess() async {
        let script = BrowserDesignModeScript(resourceURL: nil)

        await #expect(throws: CocoaError.self) {
            try await script.source()
        }
    }
}
