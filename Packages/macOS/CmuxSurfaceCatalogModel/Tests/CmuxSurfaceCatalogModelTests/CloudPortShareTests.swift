import CmuxSurfaceCatalogModel
import Foundation
import Testing

/// The one plan the app's share control and `cmux vm share` both execute, and
/// the freshness policy that keeps port badges current without a request storm.
@Suite struct CloudPortShareTests {
    private static func ref(
        _ id: String, port: Int = 3000, vm: String = "vm-1", _ sharing: CloudPortSharing, generated: Bool = true
    ) -> CloudPortPublicationRef {
        CloudPortPublicationRef(
            id: id, hostname: "\(id).example.test", url: "https://\(id).example.test",
            vmID: vm, port: port, sharing: sharing, isGeneratedDomain: generated
        )
    }

    @Test func statusIsTheWidestAudienceOfThatPortOnly() {
        let plan = CloudPortSharePlan(
            publications: [
                Self.ref("a", .personal), Self.ref("b", .public), Self.ref("c", .team),
                Self.ref("other-port", port: 4000, .public), Self.ref("other-vm", vm: "vm-2", .public),
            ],
            machineID: "vm-1", port: 3000
        )
        #expect(plan.current == .public)
        #expect(plan.publications.map(\.id) == ["b", "c", "a"])
        #expect(plan.primary?.id == "b")
        #expect(plan.selectedAudience == .public)
        #expect(!plan.requiresPublicConfirmation(.audience(.public)))
    }

    @Test func anUnsharedPortIsPrivateAndSharingCreatesOneLink() {
        let plan = CloudPortSharePlan(publications: [], machineID: "vm-1", port: 3000)
        #expect(plan.current == .unshared)
        #expect(!plan.isShared)
        #expect(plan.selectedAudience == nil)
        #expect(plan.steps(to: .audience(.team)) == [.create(.team)])
        #expect(plan.steps(to: .stopSharing).isEmpty)
        #expect(plan.requiresPublicConfirmation(.audience(.public)))
        #expect(!plan.requiresPublicConfirmation(.audience(.team)))
        #expect(!plan.requiresPublicConfirmation(.stopSharing))
    }

    @Test func aChosenAudienceAppliesToEveryLinkThatDiffers() {
        let plan = CloudPortSharePlan(
            publications: [Self.ref("a", .personal), Self.ref("b", .public), Self.ref("c", .team)],
            machineID: "vm-1", port: 3000
        )
        #expect(plan.steps(to: .audience(.personal)) == [.update(id: "b", .personal), .update(id: "c", .personal)])
        #expect(plan.steps(to: .audience(.public)) == [.update(id: "c", .public), .update(id: "a", .public)])
        let already = CloudPortSharePlan(publications: [Self.ref("t", .team)], machineID: "vm-1", port: 3000)
        #expect(already.steps(to: .audience(.team)).isEmpty)
    }

    @Test func stopSharingRemovesGeneratedLinksAndNarrowsCustomDomains() {
        let plan = CloudPortSharePlan(
            publications: [
                Self.ref("gen", .public),
                Self.ref("custom", .team, generated: false),
                Self.ref("mine", .personal, generated: false),
            ],
            machineID: "vm-1", port: 3000
        )
        #expect(plan.steps(to: .stopSharing) == [.delete(id: "gen"), .update(id: "custom", .personal)])
        #expect(plan.customDomainsKeptByStopSharing.map(\.id) == ["custom", "mine"])
    }

    @Test func readsTheSocketPublicationPayload() {
        let row: [String: Any] = [
            "id": "pub_1", "hostname": "x.cmux.sh", "url": "https://x.cmux.sh", "domainKind": "custom",
            "vmId": "vm-1", "port": NSNumber(value: 3000), "accessMode": "team",
        ]
        let ref = CloudPortPublicationRef(foundationObject: row)
        #expect(ref?.port == 3000)
        #expect(ref?.sharing == .team)
        #expect(ref?.isGeneratedDomain == false)
        #expect(CloudPortPublicationRef(foundationObject: ["vmId": "vm-1", "port": 3000]) == nil)
        let generated = CloudPortPublicationRef(foundationObject: ["id": "p", "vmId": "v", "targetPort": "80", "hostname": "h"])
        #expect(generated?.isGeneratedDomain == true)
        #expect(generated?.url == "https://h")
    }

    @Test func freshnessAllowsOneReadPerTTLAndNoneInFlight() {
        let start = Date(timeIntervalSince1970: 1_000)
        var freshness = CloudPortSharingFreshness(ttl: 120, failureBackoff: 30)
        #expect(freshness.shouldFetch(now: start))
        let token = freshness.begin()
        // A whole tree of rows appearing at once asks again and again; only one read runs.
        #expect(!freshness.shouldFetch(now: start))
        freshness.succeed(token: token, now: start)
        #expect(freshness.hasLoaded)
        #expect(!freshness.shouldFetch(now: start.addingTimeInterval(119)))
        #expect(freshness.shouldFetch(now: start.addingTimeInterval(120)))
    }

    @Test func aFailureBacksOffAndAShareChangeReadsAtOnce() {
        let start = Date(timeIntervalSince1970: 1_000)
        var freshness = CloudPortSharingFreshness(ttl: 120, failureBackoff: 30)
        _ = freshness.begin()
        freshness.fail(now: start)
        #expect(!freshness.shouldFetch(now: start.addingTimeInterval(29)))
        #expect(freshness.shouldFetch(now: start.addingTimeInterval(30)))

        let token = freshness.begin()
        freshness.succeed(token: token, now: start)
        #expect(!freshness.shouldFetch(now: start.addingTimeInterval(1)))
        freshness.invalidate()
        #expect(freshness.shouldFetch(now: start.addingTimeInterval(1)))
    }

    @Test func aReadThatStartedBeforeAShareChangeDoesNotCountAsFresh() {
        let start = Date(timeIntervalSince1970: 1_000)
        var freshness = CloudPortSharingFreshness(ttl: 120, failureBackoff: 30)
        let stale = freshness.begin()
        freshness.invalidate()
        freshness.succeed(token: stale, now: start)
        #expect(freshness.shouldFetch(now: start.addingTimeInterval(1)))
    }
}
