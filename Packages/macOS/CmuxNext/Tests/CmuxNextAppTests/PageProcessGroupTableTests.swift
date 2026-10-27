import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextChiefViews
@testable import CmuxNextDiff
import CmuxNextPages
import Foundation
import Testing

/// The process group of every page the app ships (p13-webui.md 3.B, task 087), checked from each
/// descriptor's capability (``PageCapability``), which reads the descriptor's own op tables
/// (``PageOpTable``): the router admits only the ops a table lists, so a provider's new op is
/// reachable only once its table names it, and then this suite sees it. Each descriptor's
/// ``PageDescriptor/processGroup`` is the group this table names (task 012), so a descriptor cannot
/// change group without the audit. The group reaches Chromium only with the `pageProcessGroups`
/// feature on, and only for a group that shares a renderer.
@MainActor
@Suite struct PageProcessGroupTableTests {
    /// The groups as the test decides them. Section 3.B as written fails (see
    /// ``theSectionTableAsWrittenFails()``): markdown saves files, home-channels loads the daemon's
    /// credential, Settings and the changelog have undeclared namespaces, and Files, Chief Views and
    /// Agent Activity act while they show outside text (open a file, set the fleet URL and open a link,
    /// stop a session), so each takes its own renderer; the icon picker shows only app data, so it
    /// shares with the privileged pages.
    static let groups: [PageProcessGroup: [PageDescriptor]] = [
        .agent: [.agent],
        .privileged: [.cloud, .apps, .coderouter, .keybindings, .debugSettings, .mobilePairing, .history, .stats, .chiefUsage,
                      .iconPicker],
        .viewer: [.chiefInspector],
        .solo: [.diff, .editor, .changelog, .markdown, .settings, .homeChannels, .files, .chiefViews, .agentActivity],
        .secrets: [.passwords],
    ]

    /// Pages that show repository files or remote text their CSP and resources do not reveal: agent
    /// output, the Files tree, pull request titles, agent activity, a paired server's memory.
    static let showsOutsideText: Set<String> = [
        PageDescriptor.agent.id, PageDescriptor.files.id, PageDescriptor.chiefViews.id, PageDescriptor.agentActivity.id,
        PageDescriptor.chiefInspector.id,
    ]

    static var shipped: [PageDescriptor] { FirstPartyPageSchemes.descriptors + [.chiefViews] }

    static func capability(_ page: PageDescriptor) -> PageCapability {
        PageCapability(page, showsOutsideText: showsOutsideText.contains(page.id))
    }

    static func audit(_ table: [PageProcessGroup: [PageDescriptor]]) -> PageProcessGroupAudit {
        PageProcessGroupAudit(table.mapValues { $0.map(capability) })
    }

    @Test func everyShippedPageHasExactlyOneGroup() {
        let grouped = Self.groups.values.flatMap { $0 }.map(\.id)
        #expect(grouped.count == 22)
        #expect(grouped.count == Set(grouped).count, "a page is in two groups")
        let shipped = Set(Self.shipped.map(\.id))
        #expect(Set(grouped) == shipped, "missing: \(shipped.subtracting(grouped)), extra: \(Set(grouped).subtracting(shipped))")
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
            case .hostPower, .secrets, .outsideContentWithActions, .undeclaredOps: break
            case .appContent, .outsideContent: Issue.record("\(page.id) could share: \(Self.capability(page).summary)")
            }
        }
    }

    /// A page whose namespace has no op table never shares a renderer.
    @Test func undeclaredNamespacesAreOnlyOnPagesThatShareNothing() {
        let sharing = Set(Self.groups.filter { $0.key.sharesRenderer }.values.flatMap { $0 }.map(\.id))
        for page in Self.shipped where !Self.capability(page).undeclaredNamespaces.isEmpty {
            #expect(!sharing.contains(page.id), "\(page.id) shares with undeclared \(Self.capability(page).undeclaredNamespaces)")
        }
        // The declared pages: every namespace of each has its table.
        for page in Self.shipped where Self.groups[.privileged, default: []].contains(page) || page == .agent || page == .chiefInspector {
            #expect(Self.capability(page).undeclaredNamespaces.isEmpty, "\(page.id)")
        }
    }

    /// The tables name exactly the ops the providers dispatch, where a provider keeps its ops in one
    /// place: a table that drifts from its provider fails here.
    @Test func theTablesMatchTheirProviders() throws {
        let agent = try #require(PageDescriptor.agent.opTable(for: AgentPageOps.namespace))
        #expect(Set(agent.kinds.keys) == Set(AgentPageOps.all + [AgentPageProvider.hostEvents]))

        let diff = try #require(PageDescriptor.diff.opTable(for: "cmux.diff."))
        let diffOps = DiffPageProvider.gitOps.union(DiffPageProvider.revertOps).union(DiffPageProvider.storeOps)
            .union(DiffPageProvider.methods.map { "cmux.diff." + $0 })
            .union([DiffPageProvider.configOp, DiffPageProvider.languagesOp, DiffPageProvider.eventsStream, DiffPageProvider.recentsOp,
                    DiffPageProvider.chooseFolderOp, DiffPageProvider.openOp, DiffPageProvider.openFileOp, DiffPageProvider.prefsStream])
        #expect(Set(diff.kinds.keys) == diffOps)

        let chiefViews = try #require(PageDescriptor.chiefViews.opTable(for: ChiefViewsPageProvider.prefix))
        #expect(Set(chiefViews.kinds.keys) == [
            ChiefViewsPageProvider.agentsOp, ChiefViewsPageProvider.agentsChanged, ChiefViewsPageProvider.fleetOp,
            ChiefViewsPageProvider.setFleetURLOp, ChiefViewsPageProvider.landingOp, ChiefViewsPageProvider.openOp,
            ChiefViewsPageProvider.openURLOp,
        ])
        #expect(chiefViews.ops(.act) == [ChiefViewsPageProvider.openOp, ChiefViewsPageProvider.openURLOp,
                                         ChiefViewsPageProvider.setFleetURLOp].sorted())

        let mobile = try #require(PageDescriptor.mobilePairing.opTable(for: "cmux.mobilePairing."))
        #expect(Set(mobile.kinds.keys) == [MobilePairingPageProvider.statusOp, MobilePairingPageProvider.setAllowedOp,
                                           MobilePairingPageProvider.changesStream])
        let inspector = try #require(PageDescriptor.chiefInspector.opTable(for: "cmux.chief_inspector."))
        #expect(Set(inspector.kinds.keys) == [ChiefInspectorPageProvider.get])
        let activity = try #require(PageDescriptor.agentActivity.opTable(for: AgentActivityPageProvider.prefix))
        #expect(activity.kind(of: AgentActivityPageProvider.stateStream) == .read)
        #expect(activity.ops(.act) == [AgentActivityPageProvider.prefix + "perform"])
        let coderouter = try #require(PageDescriptor.coderouter.opTable(for: "cmux.coderouter."))
        #expect(coderouter.kind(of: CodeRouterPageProvider.connectOp) == .act)
        let iconPicker = try #require(PageDescriptor.iconPicker.opTable(for: "cmux.iconPicker."))
        #expect(iconPicker.kind(of: IconPickerProvider.sessionStream) == .read)
    }

    /// Settings and Home Channels reach the harness center's add (a person-brought command) and
    /// doctor (a real turn on it): host power, whatever else the page is.
    @Test func harnessRegistrationIsHostPower() {
        for page in [PageDescriptor.settings, .homeChannels] {
            let ops = Self.capability(page).hostPowerOps
            #expect(ops.contains("cmux.chief.backend.add") && ops.contains("cmux.chief.backend.doctor"), "\(page.id): \(ops)")
        }
        #expect(Self.capability(.settings).capabilityClass == .hostPower(page: PageDescriptor.settings.id))
    }

    /// Each dynamic prefix a shipped page serves is either the app's own (tied here to the constant
    /// its source serves) or outside content, never neither: a new prefix fails until its author
    /// puts it in one set, and a rename of a source's prefix fails the first check.
    @Test func everyDynamicPrefixIsClassified() {
        #expect(PageCapability.appOnlyPrefixes == [
            MarkdownPageResource.library, AppsPageNativeOps.glyphPrefix, IconPickerSymbols.prefix,
            SettingsBackdropThumbnails.prefix, SettingsIconAssets.prefix,
        ])
        let outside: Set<String> = [
            MarkdownPageResource.asset, MarkdownPageResource.remoteImage, DiffPatchResolver.prefix, MuseumArtSession.thumbnailPrefix,
        ]
        let served = Set(Self.shipped.flatMap(\.dynamicPrefixes))
        #expect(PageCapability.appOnlyPrefixes.isDisjoint(with: outside))
        #expect(served == PageCapability.appOnlyPrefixes.union(outside), "unclassified: \(served.subtracting(PageCapability.appOnlyPrefixes.union(outside)))")
        for page in Self.shipped {
            let reported = Set(Self.capability(page).outsideSources.filter { $0.hasPrefix("resource ") }.map { String($0.dropFirst("resource ".count)) })
            #expect(reported == page.dynamicPrefixes.intersection(outside), "\(page.id)")
        }
    }

    /// Agent Activity stops live sessions: with outside content beside it, that content could.
    @Test func agentActivityNeverSharesWithOutsideContent() {
        for peer in [PageDescriptor.files, .chiefInspector] {
            let audit = Self.audit([.viewer: [.agentActivity, peer]])
            #expect(audit.violations.map(\.group) == [.viewer], "\(peer.id)")
            #expect(audit.report.contains("cmux.agentActivity.perform (act)"), "\(audit.report)")
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
        for reason in ["cmux.chief.backend.add", "cmux.markdown.save", "cmux.host.credential.", "cmux.agentActivity.perform",
                       "cmux.chief_views.open_url"] {
            #expect(audit.report.contains(reason), "\(reason) is not named:\n\(audit.report)")
        }
    }

    @Test func everyDescriptorIsInItsAuditedGroup() {
        for (group, pages) in Self.groups {
            for page in pages {
                #expect(page.processGroup == group, "\(page.id) is in \(page.processGroup), the audited table says \(group)")
            }
        }
    }

    /// The pages Chromium serves, each with an empty bundled root.
    static func entries(processGroups: Bool) throws -> [String: CEFPageSchemes.Entry] {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "page-groups-\(UUID().uuidString)/Resources")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        var roots: [String: URL] = [:]
        for page in FirstPartyPageSchemes.descriptors {
            let root = bundle.appending(path: "pages/\(page.id)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots[page.id] = root
        }
        return FirstPartyPageSchemes.entries(roots: roots, bundleResources: bundle, processGroups: processGroups)
    }

    @Test func chromiumGetsTheSharingGroupsOnlyWithTheFeatureOn() throws {
        let on = try Self.entries(processGroups: true)
        #expect(on.count == FirstPartyPageSchemes.descriptors.count)
        for page in FirstPartyPageSchemes.descriptors {
            let expected = page.processGroup.sharesRenderer ? page.processGroup.rawValue : nil
            #expect(on[page.id]?.processGroup == expected, "\(page.id) (\(page.processGroup))")
        }
        let off = try Self.entries(processGroups: false)
        #expect(off.count == FirstPartyPageSchemes.descriptors.count)
        #expect(off.values.allSatisfy { $0.processGroup == nil }, "the feature is off but an entry names a group")
    }

    /// The fork shares one renderer per group key, so a key two pages hold is a shared renderer: no
    /// `solo` or `secrets` page holds one, and every key is a sharing group's.
    @Test func noTwoSoloPagesGetOneGroupKey() throws {
        let on = try Self.entries(processGroups: true)
        let alone = FirstPartyPageSchemes.descriptors.filter { !$0.processGroup.sharesRenderer }
        #expect(alone.count >= 2, "fewer than two solo or secrets pages to compare")
        for page in alone {
            #expect(on[page.id]?.processGroup == nil, "\(page.id) (\(page.processGroup)) names a group key")
        }
        let sharing = Set(PageProcessGroup.allCases.filter(\.sharesRenderer).map(\.rawValue))
        let keys = Set(on.values.compactMap(\.processGroup))
        #expect(keys.isSubset(of: sharing), "keys outside the sharing groups: \(keys.subtracting(sharing).sorted())")
    }
}
