import CmuxNextCompat
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// The dev auto-approve (DEBUG tagged dev builds): the same tag's iPhone app of the signed-in user
/// pairs without the "Allow … to connect?" prompt; everything else still gets the prompt. The rule's
/// cases are cmux-mobile-host-core's parity tests (tests/parity.rs); these check the Swift callers.
@Suite struct IPhoneDevAutoApproveTests {
    static let user = "user-1"

    static func request(bundleID: String? = "dev.cmux.mobile.pair-fast-v1", kind: String = "phone") -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: "AB12-phone", name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                              approvalKey: kind == "phone" ? "04" + String(repeating: "bb", count: 64) : "", kind: kind,
                              bundleID: bundleID)
    }

    /// The tagged dev Mac `com.cmuxterm.app.debug.pair.fast.v1`, shipping `CMUX_TAG=pair-fast-v1` as reload.sh does.
    static func auto(bundleID: String = "com.cmuxterm.app.debug.pair.fast.v1", tag: String? = "pair-fast-v1",
                     environment: [String: String] = [:], debugBuild: Bool = true) -> IPhoneDevAutoApprove? {
        IPhoneDevAutoApprove(build: BuildIdentity(bundleID: bundleID, bundledTag: tag), environment: environment,
                             debugBuild: debugBuild)
    }

    static func approves(_ request: MobileHostPairRequest, auto: IPhoneDevAutoApprove? = Self.auto(),
                         paired: String = user, account: String? = user) -> Bool {
        IPhoneHostService.devAutoApproves(request, devAutoApprove: auto, pairedUserID: paired, accountUserID: account)
    }

    @Test func theSameTagsPhoneOfTheSignedInUserPairsWithoutThePrompt() {
        #expect(Self.auto()?.tag == "pair-fast-v1")
        #expect(Self.approves(Self.request()))
        // Bundle ids compare without case.
        #expect(Self.approves(Self.request(bundleID: "dev.cmux.mobile.Pair-Fast-V1")))
    }

    @Test func theTagComesFromTheBundleNotTheProcessEnvironment() {
        // `fromLaunch` reads `CMUX_TAG` from the bundle's LSEnvironment only: an inherited one names nothing.
        let auto = IPhoneDevAutoApprove.fromLaunch(bundle: Bundle(for: BundleMarker.self), environment: ["CMUX_TAG": "pair-fast-v1"])
        #expect(auto?.tag != "pair-fast-v1")
    }

    /// 2026-11-17 (tag `ios-onboard`): the phone, signed in, also asked another build on the same computer
    /// (tag `cu-all`), which had no code and prompted. A dev iPhone app asks any Mac but its own tag's quietly.
    @Test func anotherBuildsDevPhoneAsksQuietly() {
        let phone = Self.request()  // dev.cmux.mobile.pair-fast-v1
        #expect(IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: "cu-all"))
        #expect(IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: nil))  // NIGHTLY, RC, release
        // Its own tag's Mac still asks (--approve-first), and so does every other phone.
        #expect(!IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: "pair-fast-v1"))
        for bundleID: String? in ["com.cmux.app", "dev.cmux.app.beta", "dev.cmux.mobile.", nil] {
            #expect(!IPhoneDevAutoApprove.asksQuietly(Self.request(bundleID: bundleID), macDevTag: nil), "\(bundleID ?? "nil")")
        }
        #expect(!IPhoneDevAutoApprove.asksQuietly(Self.request(kind: "mac"), macDevTag: nil))
        // The Mac's own dev tag holds in every configuration, unlike the auto-approve.
        #expect(IPhoneDevAutoApprove.devTag(of: BuildIdentity(bundleID: "com.cmuxterm.app.debug.pair.fast.v1",
                                                              bundledTag: "pair-fast-v1")) == "pair-fast-v1")
        #expect(IPhoneDevAutoApprove.devTag(of: BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil)) == nil)
    }

    @Test func hostdForwardsThePhonesBundleID() throws {
        let line = #"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04","bundle_id":"dev.cmux.mobile.pair-fast-v1"}"#
        guard case .pairRequest(let request)? = MobileHostEvent(line: Substring(line)) else {
            Issue.record("not a pair request")
            return
        }
        #expect(request.bundleID == "dev.cmux.mobile.pair-fast-v1")
        let older = #"{"type":"pair_request","phone_device_id":"p","name":"n","identity_key":"04","approval_key":"04"}"#
        guard case .pairRequest(let without)? = MobileHostEvent(line: Substring(older)) else {
            Issue.record("not a pair request")
            return
        }
        #expect(without.bundleID == nil)
    }
}

private final class BundleMarker {}
