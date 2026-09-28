import CmuxCore
import Foundation
import Testing

@Suite("RemoteLinkOpenPolicy")
struct RemoteLinkOpenPolicyTests {
    private let policy = RemoteLinkOpenPolicy()
    private let loopbackURL = URL(string: "http://localhost:3000/callback")!
    private let sshRoute = URL(string: "http://127.0.0.1:3000/callback")!
    private let cloudRoute = URL(string: "http://10.8.0.5:3000/callback")!

    @Test func clickedSSHLoopbackLinkKeepsItsOwnURLOutsideCmux() {
        let result = policy.destinations(for: loopbackURL, machineRoute: sshRoute, remoteInitiated: false)
        #expect(result.browserURL == sshRoute)
        #expect(result.externalURL == loopbackURL)
    }

    @Test func remoteSSHLoopbackOpenNeverReachesTheDefaultBrowser() {
        let result = policy.destinations(for: loopbackURL, machineRoute: sshRoute, remoteInitiated: true)
        #expect(result.browserURL == sshRoute)
        #expect(result.externalURL == nil)
    }

    @Test(arguments: [false, true])
    func cloudRouteStaysOnTheMachineAddress(remoteInitiated: Bool) {
        let result = policy.destinations(for: loopbackURL, machineRoute: cloudRoute, remoteInitiated: remoteInitiated)
        #expect(result == RemoteLinkDestinations(browserURL: cloudRoute, externalURL: cloudRoute))
    }

    @Test(arguments: ["http://192.168.1.1/", "http://127.0.0.1:8080/", "http://169.254.169.254/latest", "http://printer.local/"])
    func remoteOpenOfAPrivateHostIsRefused(raw: String) throws {
        let url = try #require(URL(string: raw))
        let result = policy.destinations(for: url, machineRoute: nil, remoteInitiated: true)
        #expect(result == RemoteLinkDestinations(browserURL: nil, externalURL: nil))
    }

    @Test func remoteOpenOfAPublicURLOpens() throws {
        let url = try #require(URL(string: "https://github.com/login/device"))
        let result = policy.destinations(for: url, machineRoute: nil, remoteInitiated: true)
        #expect(result == RemoteLinkDestinations(browserURL: url, externalURL: url))
    }

    @Test func clickedPrivateLinkStillOpens() throws {
        let url = try #require(URL(string: "http://192.168.1.1/"))
        let result = policy.destinations(for: url, machineRoute: nil, remoteInitiated: false)
        #expect(result == RemoteLinkDestinations(browserURL: url, externalURL: url))
    }

    @Test(arguments: ["Tool.app", "run.command", "shell.terminal", "build.tool", "flow.workflow", "setup.sh", "notes.md"])
    func clickedRemoteLinkNeverOpensAFileOnThisMac(name: String) {
        let url = URL(fileURLWithPath: "/tmp/cmux-remote-link/\(name)")
        #expect(!policy.allowsLocalFile(url, localContent: false, remoteInitiated: false))
    }

    @Test func remoteOpenNeverOpensAFileOnThisMac() {
        let url = URL(fileURLWithPath: "/tmp/cmux-remote-link/run.command")
        #expect(!policy.allowsLocalFile(url, localContent: true, remoteInitiated: true))
        #expect(!policy.allowsLocalFile(url, localContent: false, remoteInitiated: true))
    }

    @Test func fileSchemeIsMatchedWithoutCase() throws {
        let url = try #require(URL(string: "FILE:///tmp/cmux-remote-link/Tool.app"))
        #expect(!policy.allowsLocalFile(url, localContent: false, remoteInitiated: false))
    }

    @Test func clickOnLocalContentOpensItsFile() {
        let url = URL(fileURLWithPath: "/tmp/cmux-remote-link/Tool.app")
        #expect(policy.allowsLocalFile(url, localContent: true, remoteInitiated: false))
    }

    @Test(arguments: [false, true])
    func webLinksAreLeftToDestinations(remoteInitiated: Bool) throws {
        let url = try #require(URL(string: "https://github.com/login/device"))
        #expect(policy.allowsLocalFile(url, localContent: false, remoteInitiated: remoteInitiated))
    }
}
