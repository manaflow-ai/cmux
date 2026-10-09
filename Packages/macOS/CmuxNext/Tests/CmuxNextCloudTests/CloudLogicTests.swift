@testable import CmuxNextCloud
import Foundation
import Testing

@Suite struct CloudConfigurationTests {
    @Test func releaseBuildIsAlwaysProduction() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app", bundled: ["CMUX_VM_API_BASE_URL": "https://example.test"],
                                                process: [:], isDebugBuild: false)
        #expect(config.backend == .production)
        #expect(config.apiBaseURL.absoluteString == "https://cmux.com")
        #expect(config.stackProjectID == CloudConfiguration.productionProjectID)
        #expect(config.keychainService == "com.cmuxterm.app.auth")
        #expect(config.callbackScheme == "cmux")
    }

    @Test func directBackendBuildUsesTheTagStack() {
        let url = "https://cmux-dev-backend-1.tail137216.ts.net:4053/"
        let config = CloudConfiguration.resolve(
            bundleID: "com.cmuxterm.app.debug.nxcloud",
            bundled: ["CMUX_VM_API_BASE_URL": url, "CMUX_DEV_BACKEND_URL": url, "CMUX_AUTH_WWW_ORIGIN": url, "CMUX_TAG": "nxcloud"],
            process: ["CMUX_VM_API_BASE_URL": "http://evil.test"], isDebugBuild: true)
        #expect(config.backend == .development(URL(string: url)!))
        #expect(config.stackProjectID == CloudConfiguration.developmentProjectID)
        #expect(config.keychainService == "com.cmuxterm.app.debug.nxcloud.auth")
        #expect(config.callbackScheme == "cmux-dev-nxcloud")
    }

    @Test func localBackendModeIsReportedAsLocalOnly() {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_VM_API_BASE_URL": "http://localhost:3811"],
                                                process: [:], isDebugBuild: true)
        #expect(config.backend == .localOnly(URL(string: "http://localhost:3811")!))
    }

    /// A callback scheme from the environment that cannot form a URL used to trap at sign-in;
    /// it is ignored and the default scheme is used.
    @Test func unusableCallbackSchemeFallsBackToTheDefault() throws {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_AUTH_CALLBACK_SCHEME": "bad scheme"],
                                                process: [:], isDebugBuild: true)
        #expect(config.callbackScheme == "cmux-dev")
        let url = config.signInURL(callbackState: "s1")
        #expect(url.path == "/handler/native-sign-in")
    }

    @Test func signInURLNestsTheNativeCallback() throws {
        let config = CloudConfiguration.resolve(bundleID: "b", bundled: ["CMUX_AUTH_WWW_ORIGIN": "https://web.test", "CMUX_TAG": "My Tag"],
                                                process: [:], isDebugBuild: true)
        let url = config.signInURL(callbackState: "s1")
        #expect(url.path == "/handler/native-sign-in")
        let after = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        #expect(after.hasPrefix("https://web.test/handler/after-sign-in"))
        #expect(after.contains("cmux-dev-my-tag://auth-callback?cmux_auth_state%3Ds1") || after.contains("cmux-dev-my-tag"))
    }
}

@Suite struct WireGuardConfigTests {
    @Test func fillsPrivateKeyAndAllRoutes() throws {
        let json = """
        {"tunnelId":"tun-1","clientConfig":"[Interface]\\nPrivateKey = \\nAddress = 100.64.0.1/32\\n\\n[Peer]\\nPublicKey = abc\\nAllowedIPs = 10.0.0.0/8\\nEndpoint = h:51820",
         "routes":["10.0.0.0/8","fd00::/8"],"network":{"cidr":"10.16.1.0/24","cidrV6":"fd0b::/64"},
         "networks":[{"cidr":"10.16.1.0/24","cidrV6":"fd0b::/64"},{"cidr":"10.20.0.0/24"}]}
        """
        let enrollment = try JSONDecoder().decode(CloudTunnelEnrollment.self, from: Data(json.utf8))
        let text = WireGuardConfig.shared.completed(enrollment, privateKey: "KEY=")
        #expect(text.contains("PrivateKey = KEY=\n"))
        #expect(text.contains("AllowedIPs = 10.16.1.0/24, fd0b::/64, 10.20.0.0/24, 10.0.0.0/8, fd00::/8"))
        #expect(text.contains("Endpoint = h:51820"))
    }
}

@Suite struct CloudLinkEventTests {
    @Test func parsesHubAndLinkLines() {
        #expect(CloudLinkEvent.parse(#"{"event":"hub-ready","routes":[],"socket":"/tmp/h.sock"}"#) == .hubReady(socket: "/tmp/h.sock"))
        let link = #"{"connection":{"state":"connected"},"event":"connection-snapshot","local_socket":"/tmp/m.sock"}"#
        #expect(CloudLinkEvent.parse(link) == .connected(localSocket: "/tmp/m.sock"))
        #expect(CloudLinkEvent.parse(#"{"event":"connection-snapshot","local_socket":""}"#) == .other)
        #expect(CloudLinkEvent.parse("not json") == .other)
    }

    @Test func splitterJoinsPartialLines() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(splitter.append(Data("1}\n{\"b\":2}\n{".utf8)) == ["{\"a\":1}", "{\"b\":2}"])
    }
}

@Suite struct CloudAPIDecodingTests {
    @Test func decodesListAndCreateShapes() throws {
        let list = #"{"id":"vm-1","provider":"freestyle","status":"running","displayName":null,"slug":"gentle-rose","createdAt":1790684381471,"address":{"ipv4":"10.0.0.1","ipv6":null}}"#
        let machine = try JSONDecoder().decode(CloudMachine.self, from: Data(list.utf8))
        #expect(machine.status == .running)
        #expect(machine.title == "gentle-rose")
        #expect(machine.address?.ipv4 == "10.0.0.1")
        let created = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-2","provider":"freestyle","displayName":"box"}"#.utf8))
        #expect(created.status == .provisioning)
        #expect(created.title == "box")
        let odd = try JSONDecoder().decode(CloudMachine.self, from: Data(#"{"id":"vm-3","status":"sleeping"}"#.utf8))
        #expect(odd.status == .unknown)
    }

    @Test func errorBodyPrefersUIMessage() {
        let body = Data(#"{"error":"vm_requires_pro","message":"raw","ui":{"message":"Upgrade to Pro"}}"#.utf8)
        #expect(CloudAPIError.from(status: 402, data: body, headerCode: nil) == .http(status: 402, code: "vm_requires_pro", message: "Upgrade to Pro"))
    }

    @Test func snapshotDecodesEitherIDKey() throws {
        #expect(try JSONDecoder().decode(CloudSnapshot.self, from: Data(#"{"snapshotId":"s1","id":"vm-1"}"#.utf8)).id == "s1")
        #expect(try JSONDecoder().decode(CloudSnapshot.self, from: Data(#"{"id":"s2","name":"n"}"#.utf8)).id == "s2")
    }
}

@Suite struct DogfoodCredentialsTests {
    @Test func prefersDogfoodFileAndNeverMixesSources() {
        let files = [
            "/h/.secrets/cmuxterm-dev.env": "export CMUX_DOGFOOD_STACK_EMAIL=\"a@x\"\nCMUX_UITEST_STACK_EMAIL=u@x\nCMUX_UITEST_STACK_PASSWORD=up\n",
        ]
        let env = ["CMUX_DOGFOOD_STACK_EMAIL": "e@x", "CMUX_DOGFOOD_STACK_PASSWORD": "ep"]
        // The file has a dogfood email without a password: skip it, take the env pair.
        #expect(DogfoodCredentials.resolve(environment: env.merging(["CMUX_DEV_AUTH_ACCOUNT": "e@x"]) { $1 }, home: "/h",
                                           read: { files[$0] }) == DogfoodCredentials(email: "e@x", password: "ep"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent", "CMUX_DEV_AUTH_ACCOUNT": "u@x"], home: "/h",
                                           read: { files[$0] }) == DogfoodCredentials(email: "u@x", password: "up"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "bogus"], home: "/h", read: { files[$0] }) == nil)
    }

    /// hmdm1 on cmux-lawrence-2 (2026-10-06): a tagged build signed in
    /// from the machine's own ~/.secrets/cmuxterm-dev.env, whose pair named
    /// another person. Coordinator decision: the ambient files (and shell
    /// exports) sign in only the machine's declared owner account
    /// (~/.config/cmux/dev-account, or CMUX_DEV_AUTH_ACCOUNT); without a
    /// declaration, or on a mismatch, the build starts signed out and says why.
    static let ambient = ["/h/.secrets/cmuxterm-dev.env":
        "CMUX_DOGFOOD_STACK_EMAIL=Other@X\nCMUX_DOGFOOD_STACK_PASSWORD=p\nCMUX_UITEST_STACK_EMAIL=agent@x\nCMUX_UITEST_STACK_PASSWORD=a\n"]

    @Test func withoutADeclaredOwnerTheAmbientFileSignsInNobody() {
        let files = Self.ambient
        let none = DogfoodCredentials.decide(environment: [:], home: "/h", read: { files[$0] })
        #expect(none.credentials == nil)
        #expect(none.refusal == .noDeclaredAccount)
        let profile = DogfoodCredentials.decide(environment: ["CMUX_DEV_AUTH_PROFILE": "personal"], home: "/h", read: { files[$0] })
        #expect(profile.credentials == nil, "an explicit profile still reads the ambient file")
    }

    @Test func theDeclaredOwnerFileAllowsOnlyItsAccount() {
        var files = Self.ambient
        files["/h/.config/cmux/dev-account"] = " other@x \n"
        #expect(DogfoodCredentials.resolve(environment: [:], home: "/h", read: { files[$0] })
            == DogfoodCredentials(email: "Other@X", password: "p"), "the owner's personal pair, case aside")
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent"], home: "/h", read: { files[$0] }) == nil,
                "the agent pair is another account")
        files["/h/.config/cmux/dev-account"] = "me@x"
        let mismatch = DogfoodCredentials.decide(environment: [:], home: "/h", read: { files[$0] })
        #expect(mismatch.credentials == nil)
        #expect(mismatch.refusal == .accountMismatch(found: "Other@X", declared: "me@x"))
    }

    /// CMUX_DEV_AUTH_ACCOUNT declares the account too, and wins over the file.
    @Test func anExpectedAccountRefusesEveryOtherAccount() {
        var files = Self.ambient
        files["/h/.config/cmux/dev-account"] = "other@x"
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_PROFILE": "agent", "CMUX_DEV_AUTH_ACCOUNT": "agent@x"],
                                           home: "/h", read: { files[$0] }) == DogfoodCredentials(email: "agent@x", password: "a"))
        #expect(DogfoodCredentials.resolve(environment: ["CMUX_DEV_AUTH_ACCOUNT": "me@x"], home: "/h", read: { files[$0] }) == nil)
    }
}
