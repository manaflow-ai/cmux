@testable import CmuxNextApp
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
        (.agent, .standard), (.history, .standard), (.cloud, .standard), (.apps, .standard), (.settings, PageFactory.settingsEngineOptions),
        (.keybindings, .standard), (.diff, DiffPageService.engineOptions), (.markdown, FilePageService.engineOptions),
        (.editor, FilePageService.engineOptions), (.iconPicker, IconPickerService.engineOptions), (.passwords, .standard),
        (.chiefInspector, .standard), (.debugSettings, .standard), (.homeChannels, PageFactory.homeChannelsEngineOptions),
        (.changelog, .standard), (.coderouter, .standard), (.files, .standard), (.stats, .standard),
        (.chiefUsage, .standard), (.mobilePairing, .standard),
    ]

    /// The pages that still show in WebKit, and why (webviews-chromium-AUDIT.md).
    private static let stillOnWebKit: [String: PageWebKitReason] = [
        PageDescriptor.agent.id: .agentChat,
        PageDescriptor.settings.id: .nativeHooks,
        PageDescriptor.diff.id: .nativeHooks,
        PageDescriptor.markdown.id: .nativeHooks,
        PageDescriptor.editor.id: .nativeHooks,
        PageDescriptor.iconPicker.id: .transparentOverlay,
        PageDescriptor.homeChannels.id: .nativeHooks,
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
