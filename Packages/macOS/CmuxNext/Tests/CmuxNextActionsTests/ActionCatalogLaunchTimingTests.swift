@testable import CmuxNextActions
import Foundation
import Testing

/// What the catalog costs at launch: the first read of `ActionCatalog.all` in a fresh process
/// (run this suite alone), then a registry built from it. Prints the times; asserts nothing
/// about them (a timing is evidence for a change, not a gate).
@MainActor
@Suite struct ActionCatalogLaunchTimingTests {
    @Test func firstCatalogReadTiming() {
        let clock = ContinuousClock()
        let started = clock.now
        let count = ActionCatalog.all.count
        let first = clock.now - started
        let again = clock.now
        _ = ActionCatalog.all.count
        let second = clock.now - again
        let registryStart = clock.now
        let registry = ActionRegistry.standard()
        let registryTime = clock.now - registryStart
        print("action-catalog-timing: first read \(first) (\(count) actions), second read \(second), standard registry \(registryTime)")
        #expect(count > 0)
        _ = registry
    }
}
