@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextPages
import Foundation
import Testing

/// Every page the app ships is in one capability group (p13-webui.md section 3.B, task 012), and the
/// group reaches Chromium only with the `pageProcessGroups` feature on. A page whose group changes, or
/// a new page, updates this table on purpose; the capability test (task 087) checks the table
/// against each page's ops.
@MainActor
@Suite struct PageProcessGroupTableTests {
    /// The 22 page descriptors and their group. `cmux.chief-views` is internal to CmuxNextChiefViews,
    /// so ChiefViewsPageTests checks its row.
    static let expected: [String: PageProcessGroup] = [
        "cmux.agent": .agent,
        "cmux.settings": .privileged, "cmux.cloud": .privileged, "cmux.apps": .privileged,
        "cmux.coderouter": .privileged, "cmux.keybindings": .privileged, "cmux.debug-settings": .privileged,
        "cmux.mobile-pairing": .privileged, "cmux.history": .privileged, "cmux.stats": .privileged,
        "cmux.chief-usage": .privileged,
        "cmux.markdown": .viewer, "cmux.files": .viewer, "cmux.icon-picker": .viewer, "cmux.chief-views": .viewer,
        "cmux.home-channels": .viewer, "cmux.agent-activity": .viewer, "cmux.chief-inspector": .viewer,
        "cmux.diff": .solo, "cmux.editor": .solo, "cmux.changelog": .solo,
        "cmux.passwords": .secrets,
    ]

    /// The descriptors this target sees: every page Chromium serves (``FirstPartyPageSchemes/descriptors``).
    static let visible: [PageDescriptor] = FirstPartyPageSchemes.descriptors

    @Test func theTableHasTheTwentyTwoPages() {
        #expect(Self.expected.count == 22)
        #expect(Set(Self.visible.map(\.id)) == Set(Self.expected.keys).subtracting(["cmux.chief-views"]),
                "a shipped page is missing from the group table, or the table names a page the app does not ship")
    }

    @Test func everyPageIsInItsGroup() {
        for page in Self.visible {
            #expect(page.processGroup == Self.expected[page.id], "\(page.id) is in \(page.processGroup)")
        }
    }

    @Test func chromiumGetsTheGroupsOnlyWithTheFeatureOn() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "page-groups-\(UUID().uuidString)/Resources")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        var roots: [String: URL] = [:]
        for page in Self.visible {
            let root = bundle.appending(path: "pages/\(page.id)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots[page.id] = root
        }
        let on = FirstPartyPageSchemes.entries(roots: roots, bundleResources: bundle, processGroups: true)
        #expect(on.count == Self.visible.count)
        for page in Self.visible {
            #expect(on[page.id]?.processGroup == page.processGroup.rawValue, "\(page.id)")
        }
        let off = FirstPartyPageSchemes.entries(roots: roots, bundleResources: bundle, processGroups: false)
        #expect(off.count == Self.visible.count)
        #expect(off.values.allSatisfy { $0.processGroup == nil }, "the feature is off but an entry names a group")
    }
}
