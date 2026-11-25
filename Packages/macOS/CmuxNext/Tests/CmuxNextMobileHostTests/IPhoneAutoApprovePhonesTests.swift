import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// `mobile.autoApprovePhones` (Settings > Accounts > iPhone, off by default): with it on, a phone of
/// the signed-in user pairs as the person's Allow would; with it off, or for a machine or another
/// account, the request waits for the prompt as before (Aziz, 2026-11-20, cmux#13742). Another build's
/// dev iPhone app, which the quiet ask handles (``IPhoneDevAutoApprove/asksQuietly(_:macDevTag:)``),
/// is never auto-approved by it: it waits quietly in Settings > Mobile, as with the setting off.
@Suite struct IPhoneAutoApprovePhonesTests {
    static let user = "user-1"

    /// The App Store / TestFlight iPhone app.
    static let prodPhone = "com.cmux.app"

    static func request(kind: String = "phone", bundleID: String? = prodPhone) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: "phone-1", name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                              approvalKey: "04" + String(repeating: "bb", count: 64), kind: kind, bundleID: bundleID)
    }

    /// `macDevTag` nil: NIGHTLY, RC, release or an untagged build; a tag: that tagged dev build.
    static func approves(_ request: MobileHostPairRequest, on: Bool = true, macDevTag: String? = nil,
                         paired: String = user, account: String? = user) -> Bool {
        IPhoneHostService.autoApproves(request, on: on, macDevTag: macDevTag, pairedUserID: paired, accountUserID: account)
    }

    @Test func onAPhoneOfTheSignedInUserPairsWithoutThePrompt() {
        #expect(Self.approves(Self.request()))
    }

    @Test func offEveryPhoneAsks() {
        #expect(!Self.approves(Self.request(), on: false))
    }

    @Test func anotherAccountOrNoAccountAsks() {
        #expect(!Self.approves(Self.request(), account: "user-2"))
        #expect(!Self.approves(Self.request(), paired: "user-2"))
        #expect(!Self.approves(Self.request(), account: nil))
        #expect(!Self.approves(Self.request(), paired: "", account: ""))
    }

    @Test func aMachineStillAsks() {
        #expect(!Self.approves(Self.request(kind: "mac")))
        #expect(!Self.approves(Self.request(kind: "linux")))
    }

    /// Prod to prod is unchanged: the App Store or TestFlight phone (or an older one that names no
    /// bundle) pairs silently with a NIGHTLY or release Mac whose person turned the setting on.
    @Test func aProdPhoneOnAProdMacStillPairsSilently() {
        for bundleID: String? in [Self.prodPhone, "dev.cmux.app.beta", "dev.cmux.app.internal", "", nil] {
            #expect(Self.approves(Self.request(bundleID: bundleID)), "\(bundleID ?? "nil")")
            #expect(!IPhoneDevAutoApprove.asksQuietly(Self.request(bundleID: bundleID), macDevTag: nil), "\(bundleID ?? "nil")")
        }
    }

    /// The iPhone apps with no build space (review of #54991): the Production configuration, the shared Demo build and
    /// cmux Dev belong to NIGHTLY or release, so the setting still pairs them there, though the quiet ask holds them
    /// from the prompt. On a tagged dev Mac (another space) the setting leaves them to the quiet ask.
    @Test func aBuildSpacelessPhoneStillPairsOnANightlyOrReleaseMac() {
        for bundleID in ["dev.cmux.mobile.prod", "dev.cmux.mobile.demo", "dev.cmux.mobile.dev", "DEV.CMUX.MOBILE.PROD"] {
            #expect(IPhoneDevAutoApprove.asksQuietly(Self.request(bundleID: bundleID), macDevTag: nil), "\(bundleID)")
            #expect(Self.approves(Self.request(bundleID: bundleID)), "\(bundleID)")
            #expect(!Self.approves(Self.request(bundleID: bundleID), macDevTag: "pair-fast-v1"), "\(bundleID)")
        }
        // A tagged Demo build (demo-build.sh --tag X: dev.cmux.mobile.demo.X) is not one of them: it waits.
        #expect(!Self.approves(Self.request(bundleID: "dev.cmux.mobile.demo.pair-fast-v1")))
    }

    /// The hole (route audit 2026-11-24): another build's dev iPhone app reached a Mac with the setting
    /// on and paired silently, before the quiet ask could hold it. It now waits quietly instead.
    @Test func anotherBuildsDevPhoneWaitsQuietlyWithTheSettingOn() {
        // On NIGHTLY or release: any dev iPhone app, a tagged review build's, cmux Dev (`dev.cmux.mobile.dev`)
        // or a Demo build named like a tagged one. Bundle ids compare without case.
        for bundleID in ["dev.cmux.mobile.ios-onboard", "dev.cmux.mobile.demo.ios-onboard", "dev.cmux.mobile.Pair-Fast-V1"] {
            #expect(!Self.approves(Self.request(bundleID: bundleID)), "\(bundleID)")
        }
        // On a tagged dev Mac: another tag's dev iPhone app, also a tag that only starts the same.
        for bundleID in ["dev.cmux.mobile.other-tag", "dev.cmux.mobile.pair-fast-v10", "dev.cmux.mobile.pair-fast"] {
            #expect(!Self.approves(Self.request(bundleID: bundleID), macDevTag: "pair-fast-v1"), "\(bundleID)")
        }
    }

    /// What the quiet ask does not hold is the setting's, as before: the same tag's dev iPhone app on its
    /// own dev Mac (the dev auto-approve's phone, also with `--approve-first`) and a prod phone on a tagged
    /// dev Mac.
    @Test func theQuietAskDecidesOnlyForAnotherBuildsDevPhone() {
        #expect(Self.approves(Self.request(bundleID: "dev.cmux.mobile.pair-fast-v1"), macDevTag: "pair-fast-v1"))
        #expect(Self.approves(Self.request(bundleID: Self.prodPhone), macDevTag: "pair-fast-v1"))
        #expect(Self.approves(Self.request(bundleID: nil), macDevTag: "pair-fast-v1"))
    }

    /// The rule, over every pair: the setting never pairs a request the quiet ask would hold, and with
    /// the setting on it pairs every other phone of the signed-in user.
    @Test func theSettingNeverPairsWhatTheQuietAskHolds() {
        let bundles: [String?] = [Self.prodPhone, "dev.cmux.app.beta", nil, "", "dev.cmux.mobile.", "dev.cmux.mobile.dev",
                                  "dev.cmux.mobile.prod", "dev.cmux.mobile.demo", "dev.cmux.mobile.demo.other-tag",
                                  "dev.cmux.mobile.pair-fast-v1", "DEV.CMUX.MOBILE.PAIR-FAST-V1", "dev.cmux.mobile.other-tag"]
        for bundleID in bundles {
            for macDevTag: String? in [nil, "pair-fast-v1", "other-tag", "dev"] {
                let request = Self.request(bundleID: bundleID)
                let quiet = IPhoneDevAutoApprove.asksQuietly(request, macDevTag: macDevTag)
                    && !IPhoneHostService.pairsWithoutBuildSpace(request, macDevTag: macDevTag)
                #expect(Self.approves(request, macDevTag: macDevTag) == !quiet, "\(bundleID ?? "nil") on \(macDevTag ?? "nightly")")
            }
        }
    }
}
