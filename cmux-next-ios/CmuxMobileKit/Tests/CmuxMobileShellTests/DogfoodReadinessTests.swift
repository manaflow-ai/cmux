import CmuxMobileLive
import Foundation
import Testing
@testable import CmuxMobileShell

#if DEBUG && os(iOS)
/// The hand-off's readiness receipt (`cmux-next-ios/scripts/review.sh`): which session it names,
/// which Mac it lists as linked, and that it carries no secret.
@Suite struct DogfoodReadinessTests {
    let base = URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")!
    let macs = [LiveAPI.Mac(deviceId: "mac-tagged", name: "cmux DEV cnx", online: true),
                LiveAPI.Mac(deviceId: "mac-other", name: "Other", online: true)]

    func readiness(_ env: [String: String]) -> DogfoodReadiness {
        DogfoodReadiness(environment: env, bundle: .main)
    }

    @Test func noNonceWritesNothing() {
        #expect(readiness([:]).nonce == nil)
        #expect(readiness(["CMUX_DOGFOOD_READINESS_NONCE": ""]).nonce == nil)
        #expect(readiness(["CMUX_DOGFOOD_READINESS_NONCE": "n1"]).nonce == "n1")
    }

    @Test func injectedCredentialsAreAutoLoginAndNoneAreRestored() {
        #expect(readiness(["CMUX_MOBILE_STACK_EMAIL": "a@b.c"]).sessionSource == "auto_login")
        #expect(readiness(["CMUX_MOBILE_STACK_EMAIL": ""]).sessionSource == "restored")
        #expect(readiness([:]).sessionSource == "restored")
        // A fleet step's own session (cmux-ci run --sign-in agent): a refresh token, no password.
        #expect(readiness(["CMUX_MOBILE_STACK_REFRESH_TOKEN": "rt"]).sessionSource == "auto_login")
        #expect(readiness(["CMUX_MOBILE_STACK_REFRESH_TOKEN": ""]).sessionSource == "restored")
    }

    @Test func devTagDropsTheBundleDot() {
        #expect(DogfoodReadiness(environment: [:], bundleID: "b", info: ["CmuxMobileTag": ".my-tag"]).devTag == "my-tag")
        #expect(DogfoodReadiness(environment: [:], bundleID: "b", info: ["CmuxMobileTag": "plain"]).devTag == "plain")
        #expect(DogfoodReadiness(environment: [:], bundleID: "b", info: [:]).devTag == "")
    }

    @Test func receiptNamesThePhonesDeviceIDs() throws {
        let body = readiness([:]).body(nonce: "n", apiBase: base, email: "a@b.c", userID: "u", macs: macs, focus: nil,
                                       phoneDeviceIDs: ["link-1", "presence-1"], now: Date(timeIntervalSince1970: 0))
        let json = try #require(try JSONSerialization.jsonObject(with: DogfoodReadiness.encode(body)) as? [String: Any])
        #expect(json["phone_device_ids"] as? [String] == ["link-1", "presence-1"])
    }

    /// The receipt names the build space the app's requests carry, signed in or out, so the hand-off can
    /// require its tagged Mac's (`handoff_receipt.py --build-space`). A Demo hand-off build without
    /// `CMUX_MOBILE_DEV_TAG` sat in the default space while its Mac was in `dev:<tag>`.
    @Test func receiptNamesTheBuildSpace() throws {
        let tagged = DogfoodReadiness(environment: [:], bundleID: "dev.cmux.mobile.t", info: [:], buildSpace: "dev:t")
        let signedIn = tagged.body(nonce: "n", apiBase: base, email: "a@b.c", userID: "u", macs: macs, focus: nil,
                                   now: Date(timeIntervalSince1970: 0))
        let signedOut = tagged.signedOutBody(nonce: "n", apiBase: nil, now: Date(timeIntervalSince1970: 0))
        for body in [signedIn, signedOut] {
            let json = try #require(try JSONSerialization.jsonObject(with: DogfoodReadiness.encode(body)) as? [String: Any])
            #expect(json["build_space"] as? String == "dev:t")
        }
        let nightly = DogfoodReadiness(environment: [:], bundleID: "b", info: [:])
        let json = try #require(try JSONSerialization.jsonObject(
            with: DogfoodReadiness.encode(nightly.signedOutBody(nonce: "n", apiBase: nil, now: Date(timeIntervalSince1970: 0)))) as? [String: Any])
        #expect(json["build_space"] as? String == "")
    }

    @Test func signedOutReceiptNamesNoAccount() throws {
        let r = DogfoodReadiness(environment: ["CMUX_DOGFOOD_CLIENT_ID": "client"], bundleID: "dev.cmux.mobile.t",
                                 info: ["CmuxMobileTag": ".t", "CmuxMobileSourceCommit": "abc"])
        let json = try #require(try JSONSerialization.jsonObject(
            with: DogfoodReadiness.encode(r.signedOutBody(nonce: "n", apiBase: nil, now: Date(timeIntervalSince1970: 0)))) as? [String: Any])
        #expect(json["signed_in"] as? Bool == false)
        #expect(json["session_source"] as? String == "signed_out")
        #expect(json["account_email"] as? String == "")
        #expect(json["dev_tag"] as? String == "t")
        #expect(json["git_sha"] as? String == "abc")
        #expect(json["client_id"] as? String == "client")
    }

    /// The receipt names the Cloud backend the hand-off chose (`review.sh --backend`), signed in or out,
    /// and the build's own when the launch named none.
    @Test func receiptNamesTheCloudBackend() throws {
        let defaults = try #require(UserDefaults(suiteName: "DogfoodReadinessTests.\(UUID().uuidString)"))
        let stack = "https://cmux-dev-backend-1.tail137216.ts.net:3850"
        let r = DogfoodReadiness(environment: ["CMUX_NEXT_CLOUD_BACKEND": stack], bundleID: "b",
                                 info: ["CmuxMobileCloudAPIBase": "https://cloud-api-staging.cmux.dev"], defaults: defaults)
        #expect(r.body(nonce: "n", apiBase: base, email: "a@b.c", userID: "u", macs: macs, focus: nil,
                       now: Date(timeIntervalSince1970: 0)).cloud_backend == stack)
        #expect(r.signedOutBody(nonce: "n", apiBase: nil, now: Date(timeIntervalSince1970: 0)).cloud_backend == stack)
        let plain = DogfoodReadiness(environment: ["CMUX_NEXT_CLOUD_BACKEND": ""], bundleID: "b",
                                     info: ["CmuxMobileCloudAPIBase": "https://cloud-api-staging.cmux.dev"], defaults: defaults)
        #expect(plain.cloudBackend == "https://cloud-api-staging.cmux.dev")
    }

    @Test func signedInReceiptSaysSignedIn() throws {
        let body = readiness([:]).body(nonce: "n", apiBase: base, email: "a@b.c", userID: "u", macs: macs, focus: nil,
                                       now: Date(timeIntervalSince1970: 0))
        #expect(body.signed_in)
    }

    @Test func linkedOnlyWhenPairedAndConnected() {
        let r = readiness(["CMUX_DOGFOOD_CLIENT_ID": "client"])
        func linked(_ focus: DogfoodReadiness.Focus?) -> [DogfoodReadiness.PairedMac] {
            r.body(nonce: "n", apiBase: base, email: "Me@Example.com", userID: "u", macs: macs, focus: focus,
                   now: Date(timeIntervalSince1970: 0)).paired_macs
        }
        #expect(linked(nil).isEmpty)
        #expect(linked(.init(id: "mac-tagged", paired: true, connected: true))
                == [.init(id: "mac-tagged", name: "cmux DEV cnx", linked: true)])
        #expect(linked(.init(id: "mac-tagged", paired: true, connected: false)).first?.linked == false)
        #expect(linked(.init(id: "mac-tagged", paired: false, connected: true)).first?.linked == false)
        #expect(linked(.init(id: "unlisted", paired: true, connected: true)).first?.name == "")
    }

    @Test func receiptKeysAndNoSecrets() throws {
        let body = readiness(["CMUX_DOGFOOD_CLIENT_ID": "client", "CMUX_MOBILE_STACK_EMAIL": "me@example.com",
                              "CMUX_MOBILE_STACK_PASSWORD": "hunter2"])
            .body(nonce: "nonce-1", apiBase: base, email: "Me@Example.com", userID: "user-1", macs: macs,
                  focus: .init(id: "mac-tagged", paired: true, connected: true), now: Date(timeIntervalSince1970: 0))
        let data = try DogfoodReadiness.encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema"] as? Int == 1)
        #expect(json["nonce"] as? String == "nonce-1")
        #expect(json["client_id"] as? String == "client")
        #expect(json["account_email"] as? String == "me@example.com")
        #expect(json["session_source"] as? String == "auto_login")
        #expect(json["user_id"] as? String == "user-1")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("hunter2"))
        for key in json.keys {
            for word in ["token", "password", "secret", "cookie"] { #expect(!key.lowercased().contains(word)) }
        }
    }
}
#endif
