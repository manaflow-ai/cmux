import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextPages
import Foundation
import Testing

/// Every cmux page the app ships shows in Chromium when `browser.defaultEngine` is Chromium (the
/// default): Chromium's `cmux-page://` scheme serves it (``FirstPartyPageSchemes``) and
/// ``PageEnginePolicy`` picks Chromium for it with the options its service makes it with. A page
/// that still stays on WebKit is listed in ``stillOnWebKit`` with its reason, so each slice that
/// moves a page shrinks that table.
@MainActor
@Suite struct PageChromiumCoverageTests {
    /// Every page the app ships, with the engine options its service makes it with.
    private static let surfaces: [(page: PageDescriptor, options: PageEngineOptions)] = [
        (.agent, PageEngineOptions(chromiumAgentChat: AgentPaneTunables.chromium.value)), (.history, .standard), (.cloud, .standard), (.apps, .standard), (.settings, PageFactory.settingsEngineOptions),
        (.keybindings, .standard), (.diff, DiffPageService.engineOptions), (.markdown, FilePageService.engineOptions),
        (.editor, FilePageService.engineOptions), (.iconPicker, IconPickerService.engineOptions), (.passwords, .standard),
        (.chiefInspector, .standard), (.debugSettings, .standard), (.homeChannels, PageFactory.homeChannelsEngineOptions),
        (.changelog, .standard), (.coderouter, .standard), (.files, .standard), (.stats, .standard),
        (.chiefUsage, .standard), (.mobilePairing, .standard), (.agentActivity, .standard),
    ]

    /// The pages that still show in WebKit, and why (webviews-chromium-AUDIT.md).
    private static let stillOnWebKit: [String: PageWebKitReason] = [
        PageDescriptor.iconPicker.id: .transparentOverlay,
    ]

    /// A bundle with a resource folder for every shipped page, and the table Chromium gets for it.
    private static func servedTable() throws -> (entries: [String: CEFPageSchemesEntryView], bundle: URL) {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "page-coverage-\(UUID().uuidString)/Resources")
        var roots: [String: URL] = [:]
        for (page, _) in surfaces {
            let root = bundle.appending(path: "pages/\(page.resource)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots[page.id] = root
        }
        let entries = FirstPartyPageSchemes.entries(roots: roots, bundleResources: bundle)
        return (entries.mapValues { CEFPageSchemesEntryView(csp: $0.csp, dynamicPrefixes: Set($0.dynamicPrefixes)) }, bundle)
    }

    @Test func chromiumServesEveryShippedPageWithItsOwnPolicy() throws {
        let (entries, bundle) = try Self.servedTable()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        for (page, _) in Self.surfaces {
            let entry = try #require(entries[page.id], "Chromium does not serve \(page.id)")
            #expect(entry.csp == page.csp.header, "\(page.id) gets another CSP in Chromium")
            // Chromium asks the page host for exactly the page's generated paths.
            #expect(entry.dynamicPrefixes == page.dynamicPrefixes, "\(page.id) dynamic prefixes")
        }
    }

    @Test func everyShippedPageShowsInChromiumUnlessListedWithItsReason() throws {
        let (entries, bundle) = try Self.servedTable()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        for (page, options) in Self.surfaces {
            let decision = PageEnginePolicy(preference: .chromium, chromiumAvailable: true, chromiumServes: entries[page.id] != nil)
                .decide(for: page, options: options)
            if let reason = Self.stillOnWebKit[page.id] {
                #expect(decision == .webKit(reason), "\(page.id): \(decision)")
            } else {
                #expect(decision == .chromium, "\(page.id) shows in WebKit: \(String(describing: decision.webKitReason))")
            }
        }
    }

    /// The viewer pages (Markdown, editor, diff) live in the app's resources, not the pages bundle:
    /// their root is the one registered at launch, and Chromium serves each page's own entry file.
    @Test func theViewerPagesAreServedFromTheirRegisteredRootWithTheirEntry() throws {
        let resources = FileManager.default.temporaryDirectory.appending(path: "viewer-roots-\(UUID().uuidString)/Resources")
        defer { try? FileManager.default.removeItem(at: resources.deletingLastPathComponent()) }
        let shared = PageDescriptor.diffRoot(inAppResources: resources)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let viewers: [PageDescriptor] = [.diff, .markdown, .editor]
        let roots = FirstPartyPageSchemes.bundledRoots { id in viewers.contains { $0.id == id } ? shared : nil }
        for page in viewers { #expect(roots[page.id] == shared, "\(page.id) has no root") }
        let entries = FirstPartyPageSchemes.entries(roots: roots.filter { id, _ in viewers.contains { $0.id == id } }, bundleResources: resources)
        #expect(entries[PageDescriptor.diff.id]?.entry == "diff-page.html")
        #expect(entries[PageDescriptor.markdown.id]?.entry == "markdown-page.html")
        #expect(entries[PageDescriptor.editor.id]?.entry == "editor-page.html")
    }

    @Test func aReservedIDTheAppDoesNotShipIsNeverServed() {
        let bundle = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources")
        let root = bundle.appending(path: "pages/x")
        #expect(FirstPartyPageSchemes.refusal(id: "cmux.not-a-page", root: root, bundleResources: bundle) != nil)
        #expect(FirstPartyPageSchemes.refusal(id: "com.example.app", root: root, bundleResources: bundle) == .notReserved("com.example.app"))
    }
}

/// The part of a Chromium scheme entry these tests read.
private struct CEFPageSchemesEntryView {
    let csp: String
    let dynamicPrefixes: Set<String>
}
