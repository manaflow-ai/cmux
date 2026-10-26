import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextPages
import Foundation
import Testing

/// The `cmuxPageRendererSharing` feature (p07-memory 049): the app's scheme table gives every page whose
/// group shares a renderer (``PageProcessGroup/sharesRenderer``) the shared renderer's main-frame cap, so
/// PL-memory's `cmux-page-scheme-process-per-site` names it; a `solo` or `secrets` page never gets one, so
/// it never joins a live renderer. Off, no page has a cap and Chromium gets no switch.
@MainActor
@Suite struct PageRendererSharingTableTests {
    /// The pages Chromium serves, each with an empty bundled root.
    private static func entries(rendererSharing: Bool, processGroups: Bool = false) throws -> [String: CEFPageSchemes.Entry] {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "page-sharing-\(UUID().uuidString)/Resources")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        var roots: [String: URL] = [:]
        for page in FirstPartyPageSchemes.descriptors {
            let root = bundle.appending(path: "pages/\(page.id)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots[page.id] = root
        }
        return FirstPartyPageSchemes.entries(roots: roots, bundleResources: bundle, processGroups: processGroups,
                                             rendererSharing: rendererSharing)
    }

    @Test(arguments: [false, true])
    func everySharingPageGetsTheCapAndNoSoloOrSecretsPageDoes(processGroups: Bool) throws {
        let on = try Self.entries(rendererSharing: true, processGroups: processGroups)
        #expect(on.count == FirstPartyPageSchemes.descriptors.count)
        for page in FirstPartyPageSchemes.descriptors {
            let expected = page.processGroup.sharesRenderer ? CEFPageSchemes.sharedRendererMainFrames : nil
            #expect(on[page.id]?.mainFrameCap == expected, "\(page.id) (\(page.processGroup))")
        }
        #expect(on[PageDescriptor.agent.id]?.mainFrameCap == 8, "New Tab and the chats do not share one renderer")
        #expect(on[PageDescriptor.passwords.id]?.mainFrameCap == nil, "the passwords page would join a shared renderer")
        #expect(on[PageDescriptor.diff.id]?.mainFrameCap == nil, "a solo page would join a shared renderer")
    }

    @Test func theFeatureOffGivesNoCapAndNoSwitch() throws {
        let off = try Self.entries(rendererSharing: false)
        #expect(off.values.allSatisfy { $0.mainFrameCap == nil }, "the feature is off but a page has a cap")
        #expect(CEFPageSchemes.siteCaps(off).isEmpty)
        let switches = CEFSwitches.current(forkAPIVersion: CEFForkFeatures.pageSiteSharingForkAPI, rendererPaths: true,
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                           pageSiteCaps: CEFPageSchemes.siteCaps(off))
        #expect(!switches.arguments.contains { $0.hasPrefix(CEFSwitches.pageSchemeProcessPerSite) }, "\(switches.arguments)")
    }

    /// The fork drops an entry it cannot parse (`ParseCaps` in cmux_page_groups.cc: a host of labels of
    /// lowercase letters, digits and '-', a cap above 0), and a dropped page would quietly keep its own
    /// renderers. Every entry of the shipped table parses, with and without its groups.
    @Test(arguments: [false, true])
    func everyEntryOfTheShippedTableParsesAsTheForkReadsIt(processGroups: Bool) throws {
        let caps = CEFPageSchemes.siteCaps(try Self.entries(rendererSharing: true, processGroups: processGroups))
        let argument = CEFSwitches.pageSchemeProcessPerSiteArgument(caps)
        let value = argument.dropFirst(CEFSwitches.pageSchemeProcessPerSite.count + 1)
        func isLabel(_ label: Substring) -> Bool {
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
        let parsed = value.split(separator: ",").compactMap { entry -> String? in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isLabel),
                  (Int(parts[1]) ?? 0) > 0 else { return nil }
            return String(parts[0])
        }
        let sharingPages = FirstPartyPageSchemes.descriptors.filter(\.processGroup.sharesRenderer)
        let groups = processGroups ? Set(sharingPages.map(\.processGroup.rawValue)) : []
        #expect(parsed == (sharingPages.map(\.id) + groups).sorted(), "\(argument)")
    }

    /// What the table can share today. The fork registers a page's group only when the host's last
    /// label is that group (`cmux_page_scheme_set_group`, webui-DESIGN.md 3.2), and every page host is
    /// `cmux.<page>`: only the agent page (`cmux.agent`, group `agent`) qualifies. So History and Cloud
    /// open beside a chat still get a renderer each; only the agent page's own instances share. When
    /// the `<page>.<group>` hosts land this list grows and the feature's description must change.
    @Test func onlyTheAgentPagesHostCanTakeItsGroup() {
        let registrable = FirstPartyPageSchemes.descriptors.filter { page in
            page.processGroup.sharesRenderer && page.id.split(separator: ".").last.map(String.init) == page.processGroup.rawValue
        }
        #expect(registrable.map(\.id) == [PageDescriptor.agent.id])
    }
}
