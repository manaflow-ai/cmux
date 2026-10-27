@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The capability classes the process groups follow (p13-webui.md 3.B, task 087). The table of every
/// shipped page is in CmuxNextAppTests' PageProcessGroupTableTests, where all the descriptors are visible.
@MainActor
struct PageProcessGroupCapabilityTests {
    /// A page with the agent page's host power (its descriptor lives in CmuxNextAgentPane).
    static let agentLike = PageDescriptor(
        id: "cmux.test-agent", resource: "test-agent", processGroup: .solo, namespaces: ["cmux.testAgent."],
        opTables: [PageOpTable(namespace: "cmux.testAgent.", read: ["chat.tail"], act: ["shell.run", "git.push"])])

    static let passwordsLike = PageDescriptor(id: "cmux.test-passwords", resource: "test-passwords", processGroup: .solo, namespaces: ["cmux.passwords."])

    /// A viewer page that shows outside text and only reads, as Files did before `open`.
    static func viewer(adding extra: Set<String> = []) -> PageDescriptor {
        PageDescriptor(id: "cmux.test-viewer", resource: "test-viewer", processGroup: .solo, namespaces: ["cmux.testViewer."],
                       opTables: [PageOpTable(namespace: "cmux.testViewer.", read: Set(["root", "list"]).union(extra))])
    }

    @Test func aTableCannotDeclareHostPowerWeaker() {
        let agent = PageCapability(Self.agentLike)
        #expect(agent.hostPowerOps == ["cmux.testAgent.git.push", "cmux.testAgent.shell.run"])
        #expect(agent.capabilityClass == .hostPower(page: Self.agentLike.id))
        let table = PageOpTable(namespace: "cmux.x.", read: ["save", "shell.run", "list"])
        #expect(table.ops(.hostPower) == ["cmux.x.save", "cmux.x.shell.run"])
        #expect(table.ops(.read) == ["cmux.x.list"])
        // The harness center's add and doctor are host power by full name only.
        let backend = PageOpTable(namespace: "cmux.chief.backend.", read: ["list", "add", "doctor"])
        #expect(backend.ops(.hostPower) == ["cmux.chief.backend.add", "cmux.chief.backend.doctor"])
        #expect(PageOpTable(namespace: "cmux.other.", read: ["add"]).ops(.read) == ["cmux.other.add"])
    }

    @Test func anOpTheDescriptorDeniesGivesNoPower() {
        let page = PageDescriptor(id: "cmux.test-denied", resource: "test", processGroup: .solo, namespaces: ["cmux.testDenied."],
                                  denied: ["cmux.testDenied.shell.run"],
                                  opTables: [PageOpTable(namespace: "cmux.testDenied.", read: ["list"], act: ["shell.run"])])
        let capability = PageCapability(page)
        #expect(capability.hostPowerOps.isEmpty)
        #expect(capability.capabilityClass == .appContent)
    }

    @Test func aDeclaredNamespaceAdmitsOnlyItsTable() {
        let page = Self.viewer()
        #expect(page.admits("cmux.testViewer.list"))
        #expect(!page.admits("cmux.testViewer.save"), "an op the table does not list never reaches the provider")
        #expect(!page.admits("cmux.testViewer."))
        // An undeclared namespace still admits everything under it.
        let undeclared = PageDescriptor(id: "cmux.test-open", resource: "test", processGroup: .solo, namespaces: ["cmux.testOpen."])
        #expect(undeclared.admits("cmux.testOpen.anything"))
    }

    /// The router refuses an op outside the table before any provider sees it.
    @Test func theRouterRefusesAnOpOutsideTheTable() async {
        let provider = RecordingPageProvider()
        let router = PageRouter(descriptor: Self.viewer(), routes: [PageRoute(prefix: "cmux.testViewer.", provider: provider)])
        let refused = await router.handle(["t": "call", "id": 1, "op": "cmux.testViewer.save", "params": .object([:])])
        #expect(refused["t"]?.stringValue == "err")
        #expect(refused["code"]?.stringValue == "cmux.protocol.unknown_op")
        let answered = await router.handle(["t": "call", "id": 2, "op": "cmux.testViewer.list", "params": .object([:])])
        #expect(answered["t"]?.stringValue == "ok")
        #expect(provider.ops == ["cmux.testViewer.list"])
    }

    @Test func anUndeclaredNamespaceSharesWithNoOtherPage() {
        let open = PageDescriptor(id: "cmux.test-open", resource: "test", processGroup: .solo, namespaces: ["cmux.testOpen."])
        #expect(PageCapability(open).capabilityClass == .undeclaredOps(page: open.id))
        #expect(PageCapability(open).undeclaredNamespaces == ["cmux.testOpen."])
        let audit = PageProcessGroupAudit([.privileged: [PageCapability(.history), PageCapability(open)]])
        #expect(audit.violations.map(\.group) == [.privileged])
        #expect(audit.report.contains("cmux.testOpen.*"))
    }

    /// The harness center's add and doctor under an undeclared namespace (Settings) are still named.
    @Test func harnessOpsUnderAnUndeclaredNamespaceAreHostPower() {
        let page = PageDescriptor(id: "cmux.test-settings", resource: "test", processGroup: .solo, namespaces: ["cmux.testSettings.", "cmux.chief.backend."])
        let capability = PageCapability(page)
        #expect(capability.hostPowerOps == ["cmux.chief.backend.add", "cmux.chief.backend.doctor"])
        #expect(capability.capabilityClass == .hostPower(page: page.id))
    }

    @Test func fileSaveIsHostPower() {
        let markdown = PageCapability(.markdown)
        #expect(markdown.hostPowerOps == ["cmux.markdown.deleteComment", "cmux.markdown.save", "cmux.markdown.setTableWidths"])
        #expect(markdown.capabilityClass == .hostPower(page: PageDescriptor.markdown.id))
        #expect(markdown.outsideSources == ["resource __asset", "resource __image"], "__lib is the app's own")
        #expect(PageCapability(.editor).hostPowerOps == ["cmux.editor.save"])
    }

    @Test func remoteSourcesAndOutsidePrefixesAreOutsideContentButTheOwnOriginIsNot() {
        let changelog = PageCapability(.changelog)
        #expect(changelog.outsideSources == ["media-src \(PageDescriptor.changelogReelSource)"])
        let diff = PageCapability(.diff)
        #expect(diff.outsideSources == ["resource __patch"], "connect-src cmux-page://cmux.diff is its own origin")
        #expect(diff.hostPowerOps.contains("cmux.diff.git.push") && diff.hostPowerOps.contains("cmux.diff.git.discard"))
    }

    /// Fail closed: a dynamic prefix nobody listed as the app's own is outside content.
    @Test func anUnlistedDynamicPrefixIsOutside() {
        let page = PageDescriptor(id: "cmux.test-prefix", resource: "test", processGroup: .solo, namespaces: ["cmux.testPrefix."],
                                  dynamicPrefixes: ["__new", AppsPageNativeOps.glyphPrefix],
                                  opTables: [PageOpTable(namespace: "cmux.testPrefix.", read: ["list"])])
        let capability = PageCapability(page)
        #expect(capability.outsideSources == ["resource __new"])
        #expect(capability.capabilityClass == .outsideContent)
    }

    /// Opening a file in a tab acts: outside text on the Files page may not drive it for another page.
    @Test func actingOpsOnAnOutsidePageAreActions() {
        let files = PageCapability(.files, showsOutsideText: true)
        #expect(files.outsideSources == ["shown text"])
        #expect(files.actingOps == ["cmux.files.open"])
        #expect(files.capabilityClass == .outsideContentWithActions(page: PageDescriptor.files.id))
        #expect(PageCapability(Self.viewer(), showsOutsideText: true).capabilityClass == .outsideContent)
    }

    /// Red: a viewer page that gains a save or a shell op leaves the viewer group.
    @Test(arguments: ["save", "shell.run"])
    func aViewerWithAnAddedHostOpFailsTheViewerGroup(op: String) {
        let grown = PageCapability(Self.viewer(adding: [op]), showsOutsideText: true)
        #expect(grown.hostPowerOps == ["cmux.testViewer." + op])
        let other = PageDescriptor(id: "cmux.test-other-viewer", resource: "test", processGroup: .solo, namespaces: ["cmux.testOther."],
                                   opTables: [PageOpTable(namespace: "cmux.testOther.", read: ["get"])])
        let audit = PageProcessGroupAudit([.viewer: [grown, PageCapability(other, showsOutsideText: true)]])
        #expect(audit.violations.map(\.group) == [.viewer])
        #expect(audit.report.contains("cmux.testViewer.\(op) (host power)"), "\(audit.report)")
    }

    @Test func appDataPagesAreAppContent() {
        for page in [PageDescriptor.history, .cloud, .apps, .coderouter, .stats, .chiefUsage] {
            #expect(PageCapability(page).capabilityClass == .appContent, "\(page.id): \(PageCapability(page).summary)")
        }
    }

    @Test func secretsComeFromTheNamespace() {
        let passwords = PageCapability(Self.passwordsLike)
        #expect(passwords.secretOps == ["cmux.passwords."])
        #expect(passwords.capabilityClass == .secrets(page: Self.passwordsLike.id))
        let credential = PageDescriptor(id: "cmux.test-credential", resource: "test", processGroup: .solo, namespaces: ["cmux.host.credential."])
        #expect(PageCapability(credential).capabilityClass == .secrets(page: credential.id))
        // A broader namespace reaches the secrets too.
        let broad = PageDescriptor(id: "cmux.test-broad", resource: "test", processGroup: .solo, namespaces: ["cmux.host."])
        #expect(PageCapability(broad).secretOps == ["cmux.host."])
    }

    /// The design's first `content` group: the agent page with markdown and changelog. Red, and the
    /// failure names each page's ops.
    @Test func theContentGroupFailsAndListsTheOps() throws {
        let audit = PageProcessGroupAudit([
            .viewer: [PageCapability(Self.agentLike, showsOutsideText: true), PageCapability(.markdown), PageCapability(.changelog)],
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
        let agent = PageCapability(Self.agentLike)
        #expect(PageProcessGroupAudit([.agent: [agent, agent]]).violations.isEmpty)
    }

    @Test func outsideContentNeverSharesWithAppContent() {
        let audit = PageProcessGroupAudit([.privileged: [PageCapability(.history), PageCapability(Self.viewer(), showsOutsideText: true)]])
        #expect(audit.violations.map(\.group) == [.privileged])
        #expect(audit.report.contains("app content") && audit.report.contains("outside content"))
    }

    @Test func passwordsNeverShares() {
        let audit = PageProcessGroupAudit([.privileged: [PageCapability(.history), PageCapability(Self.passwordsLike)]])
        #expect(audit.violations.count == 1)
        #expect(audit.report.contains("secrets of \(Self.passwordsLike.id)"))
    }

    @Test func groupsThatDoNotShareAcceptAnyPages() {
        let pages = [PageCapability(Self.agentLike), PageCapability(.changelog), PageCapability(Self.passwordsLike)]
        #expect(PageProcessGroupAudit([.solo: pages, .secrets: pages]).violations.isEmpty)
        #expect(!PageProcessGroup.solo.sharesRenderer && !PageProcessGroup.secrets.sharesRenderer)
    }
}
