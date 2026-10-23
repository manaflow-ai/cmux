import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
import Foundation
import Testing

/// The control snapshot's Search Tabs facts are kept between publishes: a publish with nothing
/// changed builds no closed-tab list (cmux8s sidebar-churn bench, 150 workspaces: rebuilding it on
/// every publish was about 10% of main while idle), and the kept facts equal a fresh build.
@MainActor @Suite(.serialized)
struct TabSearchFactsIncrementalTests {
    /// One publish's reads, in `ControlSnapshotPublisher.publishNow`'s order.
    private static func publish(_ services: AppServices, _ cache: ControlWorkspaceInfoCache) -> ControlTabSearchFacts {
        _ = ControlSnapshotPublisher.topology(services, cache: cache)
        return TabSearchFactsBuilder.facts(services, cache: cache)
    }

    @Test func anUnchangedPublishBuildsNoClosedTabList() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = ControlWorkspaceInfoCache()
        let start = cache.memoBuilds
        let first = Self.publish(services, cache)
        let afterFirst = cache.memoBuilds
        #expect(afterFirst > start, "the first publish kept no tab search facts")
        let second = Self.publish(services, cache)
        #expect(cache.memoBuilds == afterFirst, "an unchanged publish built the tab search facts again")
        #expect(second == first)
        #expect(second.closed == TabSearchFactsBuilder.facts(services).closed)
    }
}
