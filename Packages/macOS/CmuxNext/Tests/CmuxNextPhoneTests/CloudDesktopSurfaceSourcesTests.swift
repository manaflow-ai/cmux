@testable import CmuxNextPhone
import Testing

/// hostd's `surface` tabs: `c~<machine>~<team>` is a Cloud desktop, `s<n>` stays a phone tab; and
/// the app's grant decides each start.
@MainActor
struct CloudDesktopSurfaceSourcesTests {
    @Test func onlyAWellFormedCloudDesktopTabRoutesToTheCloud() {
        #expect(CloudDesktopSurfaceSources.target(of: "c~vm-1.a~team_1") == .init(machine: "vm-1.a", team: "team_1"))
        for tab in ["s12", "c~vm-1", "c~~team", "c~vm~", "c~vm~team~extra", "x~vm~team", "c.vm.team", ""] {
            #expect(CloudDesktopSurfaceSources.target(of: tab) == nil, "\(tab)")
        }
    }

    @Test func aRefusedGrantStartsNoSource() async {
        let sources = CloudDesktopSurfaceSources { _ in throw CloudDesktopSurfaceSources.Failure.asleep }
        await #expect(throws: CloudDesktopSurfaceSources.Failure.self) {
            _ = try await sources.start(tab: "c~vm~team", onExit: {})
        }
        await #expect(throws: CloudDesktopSurfaceSources.Failure.self) {
            _ = try await sources.start(tab: "s12", onExit: {})
        }
    }

    @Test func aGrantNoLongerLiveIsRefusedAsAsleep() async {
        var fed = false
        let sources = CloudDesktopSurfaceSources { target in
            .init(feed: SurfaceFrameFeed(start: { _, _ in fed = true }, stop: {}), label: target.machine, stillLive: { false })
        }
        do {
            _ = try await sources.start(tab: "c~vm~team", onExit: {})
            Issue.record("a source started for a machine that is no longer live")
        } catch let failure as CloudDesktopSurfaceSources.Failure {
            #expect(failure.description == CloudDesktopSurfaceSources.Failure.asleep.description)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(!fed)
    }
}
