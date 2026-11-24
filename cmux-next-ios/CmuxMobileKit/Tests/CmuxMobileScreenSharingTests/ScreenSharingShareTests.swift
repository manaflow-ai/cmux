#if os(iOS)
import CmuxDeviceHub
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// Share <Mac> from the iPhone (cmuxterm-hq#18912, cut 1): no approval is signed without the
/// person's tap, and the tap's approval is the one the Mac admits, signed by this phone's hub key.
extension ScreenSharingViewerTests {
    func notSharedMac() -> HubDevice {
        HubDevice(id: hostID, name: "Studio", platform: .macos, signingKey: "", macScreenShared: false, online: true)
    }

    @Test func nothingIsSignedBeforeTheTap() {
        let (service, _) = makeService(accountID: "user-1")
        let signs = Signs()
        service.signApproval = { identity, canonical in signs.add(); return try identity.sign(canonical: canonical) }
        service.shareCarrier = { _, _, _ in Issue.record("carried without a tap") }
        service.select(notSharedMac())
        #expect(service.alert?.refusal == .notShared)
        service.listChanged()
        service.shareListed([notSharedMac()])
        #expect(signs.count == 0)
        #expect(service.sharing == nil)
    }

    @Test func withNoCarrierTheTapSignsNothingAndSaysSo() {
        let (service, _) = makeService(accountID: "user-1")
        let signs = Signs()
        service.signApproval = { identity, canonical in signs.add(); return try identity.sign(canonical: canonical) }
        service.share(notSharedMac())
        #expect(signs.count == 0)
        #expect(service.sharing == nil)
        #expect(service.shareProblem?.hostName == "Studio")
    }

    @Test func theTapSignsOnceAndCarriesTheApprovalTheMacAdmits() async throws {
        let (service, _) = makeService(accountID: "user-1")
        let identity = try #require(service.hub).identity
        let signs = Signs()
        var carried: [(String, String)] = []
        service.signApproval = { identity, canonical in signs.add(); return try identity.sign(canonical: canonical) }
        service.shareCarrier = { approval, target, _ in carried.append((approval, target.id)) }
        service.shareDeadline = .milliseconds(1)
        service.share(notSharedMac())
        #expect(service.sharing?.hostID == hostID)
        await service.shareTask?.value
        #expect(signs.count == 1)
        let (json, target) = try #require(carried.first)
        #expect(carried.count == 1 && target == hostID)
        let approval = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(approval["v"] == "cmux.share-approval.v1")
        #expect(approval["target"] == hostID && approval["target_name"] == "Studio")
        #expect(approval["asker"] == identity.id && approval["confirmed_by"] == "user-1")
        let at = try #require(approval["confirmed_at"].flatMap { UInt64($0) })
        #expect(abs(Double(at) - Date().timeIntervalSince1970) < 60)
        let nonce = try #require(approval["nonce"])
        let canonical = "cmux.share-approval.v1\ntarget=\(hostID)\nasker=\(identity.id)\nconfirmed_by=user-1\nconfirmed_at=\(at)\nnonce=\(nonce)"
        let signature = try #require(approval["signature"])
        #expect(DeviceIdentity.verify(signature: signature, of: Data(canonical.utf8), signingKey: identity.signingKey))
        // The Mac never showed up sharing within the deadline: the tap says so.
        #expect(service.sharing == nil)
        #expect(service.shareProblem?.hostName == "Studio")
    }

    @Test func aSignatureByAnotherKeyIsNeverCarried() async {
        let (service, _) = makeService(accountID: "user-1")
        let other = DeviceIdentity(deviceID: UUID(), keys: TestKeys())
        service.signApproval = { _, canonical in try other.sign(canonical: canonical) }
        service.shareCarrier = { _, _, _ in Issue.record("carried a foreign signature") }
        service.share(notSharedMac())
        await service.shareTask?.value
        #expect(service.sharing == nil)
        #expect(service.shareProblem != nil)
    }

    @Test func aSignedOutPhoneSignsNothing() async {
        let (service, _) = makeService()
        let signs = Signs()
        service.signApproval = { identity, canonical in signs.add(); return try identity.sign(canonical: canonical) }
        service.shareCarrier = { _, _, _ in Issue.record("carried while signed out") }
        service.share(notSharedMac())
        await service.shareTask?.value
        #expect(signs.count == 0)
        #expect(service.shareProblem != nil)
    }

    @Test func theMacSharingConnectsAsARowTapWould() async throws {
        let (service, _) = makeService(accountID: "user-1")
        let (carriedStream, carriedOnce) = AsyncStream<Void>.makeStream()
        service.shareCarrier = { _, _, _ in carriedOnce.yield() }
        service.share(notSharedMac(), scope: .view)
        for await _ in carriedStream { break }
        // Still not shared: it keeps waiting.
        service.shareListed([notSharedMac()])
        #expect(service.sharing?.hostID == hostID && service.viewer == nil)
        service.shareListed([mac()])
        #expect(service.sharing == nil)
        let viewer = try #require(service.viewer)
        #expect(viewer.hostID == hostID && viewer.lastScope == .view)
    }
}

final class Signs: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func add() { lock.withLock { calls += 1 } }
}
#endif
