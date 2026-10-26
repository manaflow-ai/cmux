import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextChiefViews
@testable import CmuxNextDiff
import CmuxNextPages
import Foundation
import Testing

/// The process group of every page the app ships (p13-webui.md 3.B, task 087), checked from each
/// descriptor's capability (``PageCapability``). Task 012 gives each descriptor the group this table
/// names; a change to a descriptor's ops reruns this suite.
@MainActor
@Suite struct PageProcessGroupTableTests {
    /// The groups as the test decides them. Section 3.B as written fails (see
    /// ``theSectionTableAsWrittenFails()``): markdown saves files, home-channels loads the daemon's
    /// credential and Settings shows museum thumbnails with its actions, so each takes its own
    /// renderer; the icon picker shows only app data, so it shares with the privileged pages.
    static let groups: [PageProcessGroup: [PageDescriptor]] = [
        .agent: [.agent],
        .privileged: [.cloud, .apps, .coderouter, .keybindings, .debugSettings, .mobilePairing, .history, .stats, .chiefUsage,
                      .iconPicker],
        .viewer: [.files, .chiefViews, .agentActivity, .chiefInspector],
        .solo: [.diff, .editor, .changelog, .markdown, .settings, .homeChannels],
        .secrets: [.passwords],
    ]

    /// The ops each page's providers answer under its namespaces, where a namespace alone hides
    /// host power: the agent page's whole op table, the diff page's git ops, the file pages' ops.
    static let servedOps: [String: Set<String>] = [
        PageDescriptor.agent.id: Set(AgentPageOps.all),
        PageDescriptor.diff.id: DiffPageProvider.gitOps.union(DiffPageProvider.revertOps),
        PageDescriptor.markdown.id: Set(fileOps.map { FilePageKind.markdown.op($0) }),
        PageDescriptor.editor.id: Set(fileOps.map { FilePageKind.editor.op($0) }),
    ]
    /// The file pages' ops (FilePageProvider.call).
    static let fileOps = ["config", "open", "edited", "save", "setPreference", "recents", "chooseFile", "openLink"]

    /// Pages that show repository files or remote text their CSP and resources do not reveal: agent
    /// output, the Files tree, pull request titles, agent activity, a paired server's memory.
    static let showsOutsideText: Set<String> = [
        PageDescriptor.agent.id, PageDescriptor.files.id, PageDescriptor.chiefViews.id, PageDescriptor.agentActivity.id,
        PageDescriptor.chiefInspector.id,
    ]

    static func capability(_ page: PageDescriptor) -> PageCapability {
        PageCapability(page, servedOps: servedOps[page.id] ?? [], showsOutsideText: showsOutsideText.contains(page.id))
    }

    static func audit(_ table: [PageProcessGroup: [PageDescriptor]]) -> PageProcessGroupAudit {
        PageProcessGroupAudit(table.mapValues { $0.map(capability) })
    }

    @Test func everyShippedPageHasExactlyOneGroup() {
        let shipped = (FirstPartyPageSchemes.descriptors + [.chiefViews]).map(\.id)
        let grouped = Self.groups.values.flatMap { $0 }.map(\.id)
        #expect(grouped.count == 22)
        #expect(grouped.count == Set(grouped).count, "a page is in two groups")
        #expect(Set(grouped) == Set(shipped), "missing: \(Set(shipped).subtracting(grouped)), extra: \(Set(grouped).subtracting(shipped))")
    }

    @Test func theCapabilityGroupsPass() {
        let audit = Self.audit(Self.groups)
        #expect(audit.violations.isEmpty, "\(audit.report)")
    }

    @Test func eachGroupHoldsItsClass() {
        let classes = Self.groups.mapValues { pages in Set(pages.map { Self.capability($0).capabilityClass }) }
        #expect(classes[.agent] == [.hostPower(page: PageDescriptor.agent.id)])
        #expect(classes[.privileged] == [.appContent])
        #expect(classes[.viewer] == [.outsideContent])
        #expect(classes[.secrets] == [.secrets(page: PageDescriptor.passwords.id)])
        // Every solo page has a class no other page has: it would fail in any shared group.
        for page in Self.groups[.solo] ?? [] {
            switch Self.capability(page).capabilityClass {
            case .hostPower, .secrets, .outsideContentWithActions: break
            case .appContent, .outsideContent: Issue.record("\(page.id) could share: \(Self.capability(page).summary)")
            }
        }
    }

    /// The design's first `content` group put the agent page with markdown and changelog.
    @Test func theDesignsContentGroupFails() throws {
        let audit = Self.audit([.viewer: [.agent, .markdown, .changelog]])
        let violation = try #require(audit.violations.first)
        #expect(violation.group == .viewer)
        for op in ["cmux.agent.shell.run", "cmux.agent.git.push", "cmux.agent.pane.saveFile", "cmux.markdown.save",
                   "media-src \(PageDescriptor.changelogReelSource)"] {
            #expect(audit.report.contains(op), "the failure does not list \(op):\n\(audit.report)")
        }
    }

    /// Section 3.B's table as the spec wrote it, before this test decided the groups.
    @Test func theSectionTableAsWrittenFails() {
        let audit = Self.audit([
            .agent: [.agent],
            .privileged: [.settings, .cloud, .apps, .coderouter, .keybindings, .debugSettings, .mobilePairing, .history, .stats,
                          .chiefUsage],
            .viewer: [.markdown, .files, .iconPicker, .chiefViews, .homeChannels, .agentActivity, .chiefInspector],
            .solo: [.diff, .editor, .changelog],
            .secrets: [.passwords],
        ])
        #expect(audit.violations.map(\.group) == [.privileged, .viewer])
        for reason in ["resource museum", "cmux.markdown.save", "cmux.host.credential."] {
            #expect(audit.report.contains(reason), "\(reason) is not named:\n\(audit.report)")
        }
    }
}
