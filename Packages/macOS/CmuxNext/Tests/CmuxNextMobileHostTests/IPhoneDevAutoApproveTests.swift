import CmuxNextCompat
import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// The dev auto-approve (DEBUG tagged dev builds): the same tag's iPhone app of the signed-in user
/// pairs without the "Allow … to connect?" prompt; everything else still gets the prompt.
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

    @Test func anotherAccountIsAsked() {
        #expect(!Self.approves(Self.request(), account: "user-2"))
        #expect(!Self.approves(Self.request(), paired: "user-2"))
        #expect(!Self.approves(Self.request(), account: nil))
        #expect(!Self.approves(Self.request(), paired: "", account: ""))
    }

    @Test func anotherTagOrAppIsAsked() {
        for bundleID: String? in ["dev.cmux.mobile.other-tag", "dev.cmux.mobile.pair-fast-v10", "dev.cmux.mobile.pair-fast",
                                  "dev.cmux.mobile", "dev.cmux.mobile.", "com.cmux.app", "dev.cmux.app.beta",
                                  "com.cmux.app.pair-fast-v1", "", nil] {
            #expect(!Self.approves(Self.request(bundleID: bundleID)), "\(bundleID ?? "nil")")
        }
    }

    @Test func aMachineIsAsked() {
        #expect(!Self.approves(Self.request(kind: "mac")))
        #expect(!Self.approves(Self.request(kind: "linux")))
    }

    @Test func nightlyRcStagingAndReleaseBuildsNeverAutoApprove() {
        for bundleID in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                         "com.cmuxterm.app.rc", "com.cmuxterm.app.staging.pair-fast-v1", "com.cmuxterm.app.next",
                         "com.cmux.app"] {
            #expect(Self.auto(bundleID: bundleID) == nil, "\(bundleID)")
        }
        // An untagged DEV build has no tag to match.
        #expect(Self.auto(bundleID: "com.cmuxterm.app.debug", tag: nil) == nil)
        // A Release (non-DEBUG) binary compiles none of it, even with a dev bundle id.
        #expect(Self.auto(debugBuild: false) == nil)
        #expect(!Self.approves(Self.request(), auto: nil))
    }

    @Test func approveFirstKeepsThePrompt() {
        #expect(Self.auto(environment: [IPhoneDevAutoApprove.approveFirstKey: "1"]) == nil)
        #expect(Self.auto(environment: [IPhoneDevAutoApprove.approveFirstKey: "0"]) != nil)
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

    /// A request that waits quietly (another build's dev phone) is never one the dev auto-approve of
    /// the Mac it waits on takes: that Mac is another tag's build, or no dev build at all.
    @Test func aQuietRequestNeverAutoApproves() {
        let phone = Self.request()  // dev.cmux.mobile.pair-fast-v1
        let otherTag = Self.auto(bundleID: "com.cmuxterm.app.debug.cu.all", tag: "cu-all")
        #expect(IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: otherTag?.tag))
        #expect(!Self.approves(phone, auto: otherTag))
        #expect(IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: nil))
        #expect(!Self.approves(phone, auto: nil))
        // Every request the dev auto-approve takes is one that would not wait quietly.
        #expect(Self.approves(phone) && !IPhoneDevAutoApprove.asksQuietly(phone, macDevTag: Self.auto()?.tag))
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
