import CmuxNextPages
import Foundation
import Testing

/// The capability classes the process groups follow (p13-webui.md 3.B, task 087). The table of every
/// shipped page is in CmuxNextAppTests' PageProcessGroupTableTests, where all the descriptors are visible.
@MainActor
struct PageProcessGroupCapabilityTests {
    /// A page with the agent page's host power (its descriptor lives in CmuxNextAgentPane).
    static let agentLike = PageDescriptor(id: "cmux.test-agent", resource: "test-agent", namespaces: ["cmux.testAgent."])
    static let agentOps: Set<String> = ["cmux.testAgent.shell.run", "cmux.testAgent.git.push", "cmux.testAgent.chat.tail"]

    static let passwordsLike = PageDescriptor(id: "cmux.test-passwords", resource: "test-passwords", namespaces: ["cmux.passwords."])

    @Test func hostPowerComesFromTheServedOpsUnderTheNamespace() {
        let agent = PageCapability(Self.agentLike, servedOps: Self.agentOps)
        #expect(agent.hostPowerOps == ["cmux.testAgent.git.push", "cmux.testAgent.shell.run"])
        #expect(agent.capabilityClass == .hostPower(page: Self.agentLike.id))
        // The same namespace with only read ops is no host power.
        #expect(PageCapability(Self.agentLike, servedOps: ["cmux.testAgent.chat.tail"]).capabilityClass == .appContent)
    }

    @Test func anOpTheDescriptorDeniesGivesNoPower() {
        let page = PageDescriptor(id: "cmux.test-denied", resource: "test", namespaces: ["cmux.testDenied."],
                                  denied: ["cmux.testDenied.shell.run"])
        let capability = PageCapability(page, servedOps: ["cmux.testDenied.shell.run"])
        #expect(capability.hostPowerOps.isEmpty)
        #expect(capability.capabilityClass == .appContent)
    }

    @Test func fileSaveIsHostPower() {
        let markdown = PageCapability(.markdown, servedOps: ["cmux.markdown.save", "cmux.markdown.open"])
        #expect(markdown.hostPowerOps == ["cmux.markdown.save"])
        #expect(markdown.capabilityClass == .hostPower(page: PageDescriptor.markdown.id))
        #expect(markdown.outsideSources == ["resource __asset", "resource __image"])
    }

    @Test func remoteSourcesAndOutsidePrefixesAreOutsideContentButTheOwnOriginIsNot() {
        let changelog = PageCapability(.changelog)
        #expect(changelog.outsideSources == ["media-src \(PageDescriptor.changelogReelSource)"])
        // Its "Try it" actions run on remote media's page: it shares with no other page.
        #expect(changelog.capabilityClass == .outsideContentWithActions(page: PageDescriptor.changelog.id))

        let diff = PageCapability(.diff)
        #expect(diff.outsideSources == ["resource __patch"], "connect-src cmux-page://cmux.diff is its own origin")

        let files = PageCapability(.files, showsOutsideText: true)
        #expect(files.outsideSources == ["shown text"])
        #expect(files.capabilityClass == .outsideContent)
    }

    @Test func appDataPagesAreAppContent() {
        for page in [PageDescriptor.history, .cloud, .apps, .coderouter, .stats, .chiefUsage] {
            #expect(PageCapability(page).capabilityClass == .appContent, "\(page.id)")
        }
    }

    @Test func secretsComeFromTheNamespace() {
        let passwords = PageCapability(Self.passwordsLike)
        #expect(passwords.secretOps == ["cmux.passwords."])
        #expect(passwords.capabilityClass == .secrets(page: Self.passwordsLike.id))
        let credential = PageDescriptor(id: "cmux.test-credential", resource: "test", namespaces: ["cmux.host.credential."])
        #expect(PageCapability(credential).capabilityClass == .secrets(page: credential.id))
        // A broader namespace reaches the secrets too.
        let broad = PageDescriptor(id: "cmux.test-broad", resource: "test", namespaces: ["cmux.host."])
        #expect(PageCapability(broad).secretOps == ["cmux.host."])
    }

    /// The design's first `content` group: the agent page with markdown and changelog. Red, and the
    /// failure names each page's ops.
    @Test func theContentGroupFailsAndListsTheOps() throws {
        let audit = PageProcessGroupAudit([
            .viewer: [PageCapability(Self.agentLike, servedOps: Self.agentOps, showsOutsideText: true),
                      PageCapability(.markdown, servedOps: ["cmux.markdown.save"]), PageCapability(.changelog)],
        ])
        let violation = try #require(audit.violations.first)
        #expect(audit.violations.count == 1)
        #expect(violation.group == .viewer)
        for text in ["cmux.testAgent.shell.run", "cmux.testAgent.git.push", "cmux.markdown.save",
                     "media-src \(PageDescriptor.changelogReelSource)", "action:palette.checkForUpdates", "cmux.changelog.*"] {
            #expect(audit.report.contains(text), "the failure does not list \(text):\n\(audit.report)")
        }
    }

    @Test func instancesOfOneHostPowerPageShare() {
        let agent = PageCapability(Self.agentLike, servedOps: Self.agentOps)
        #expect(PageProcessGroupAudit([.agent: [agent, agent]]).violations.isEmpty)
    }

    @Test func outsideContentNeverSharesWithAppContent() {
        let audit = PageProcessGroupAudit([.privileged: [PageCapability(.history), PageCapability(.files, showsOutsideText: true)]])
        #expect(audit.violations.map(\.group) == [.privileged])
        #expect(audit.report.contains("app content") && audit.report.contains("outside content"))
    }

    @Test func passwordsNeverShares() {
        let audit = PageProcessGroupAudit([.privileged: [PageCapability(.history), PageCapability(Self.passwordsLike)]])
        #expect(audit.violations.count == 1)
        #expect(audit.report.contains("secrets of \(Self.passwordsLike.id)"))
    }

    @Test func groupsThatDoNotShareAcceptAnyPages() {
        let pages = [PageCapability(Self.agentLike, servedOps: Self.agentOps), PageCapability(.changelog), PageCapability(Self.passwordsLike)]
        #expect(PageProcessGroupAudit([.solo: pages, .secrets: pages]).violations.isEmpty)
        #expect(!PageProcessGroup.solo.sharesRenderer && !PageProcessGroup.secrets.sharesRenderer)
    }
}
