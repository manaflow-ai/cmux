import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextUpdater
import Foundation
import Testing
import CmuxNextTestSupport

/// Hand-built menus whose rows are palette rows (cmux#45625's step B, Leo 2026-11-08: "Every conceivable possible
/// aspect of the app"): a menu row runs its registry action, so the row and its palette row run one handler. Each test
/// rebinds the action to a recorder after the App's binding, picks the menu row, and expects the recorder to run with
/// the row's arguments; before step B the rows ran their own closures and the recorder never ran.
@MainActor @Suite(.serialized) struct HandBuiltMenuPaletteRowsTests {
    static func registry() -> ActionRegistry {
        ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
    }

    /// Records the runs of `id` (the App's binding replaced).
    final class Recorder {
        var runs: [ActionInvocation] = []
        init(_ id: ActionID, in registry: ActionRegistry) {
            registry.bindEffect(id, effect: { [unowned self] invocation in
                runs.append(invocation)
                return .done
            })
        }
    }

    // MARK: Update card

    static func updater() -> UpdaterService {
        let defaults = UserDefaults(testSuiteName: "HandBuiltMenuPaletteRowsTests.\(UUID().uuidString)")!
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.menu-palette-rows", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: UpdateCardHideTests.EmptyFeed()),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.start()
        return updater
    }

    /// The update card's right-click choices run `updates.snooze` with the chosen option; the palette offers the
    /// action only while such a card shows.
    @Test func theUpdateCardsMenuRunsSnoozeAndThePaletteOffersItOnlyWithACard() {
        let updater = Self.updater()
        let registry = Self.registry()
        UpdateHandlers.bind(into: registry, updater: updater)
        #expect(!registry.canPerform("updates.snooze"), "no update card shows: the palette must not offer Snooze Update Card…")

        updater.debugStage(version: UpdateCardHideTests.version, notes: nil)
        #expect(updater.readyCard != nil)
        #expect(registry.canPerform("updates.snooze"), "the staged update's card shows: the palette offers Snooze Update Card…")
        // The real handler: a reminder hides the card.
        SidebarCardFeed.noticeAction(SidebarUpdateCard.cardID, UpdateCardCloseOption.remindDay.rawValue, updater: updater,
                                     registry: registry, open: { _ in })
        #expect(updater.readyCard == nil, "Remind Me in 1 Day did not hide the card")

        let recorder = Recorder("updates.snooze", in: registry)
        for option in UpdateCardCloseOption.allCases {
            SidebarCardFeed.noticeAction(SidebarUpdateCard.cardID, option.rawValue, updater: updater, registry: registry, open: { _ in })
        }
        #expect(recorder.runs.map { $0["option"]?.stringValue } == UpdateCardCloseOption.allCases.map(\.rawValue),
                "the card's menu rows did not run the palette's updates.snooze")
    }

    // MARK: Downloads

    /// Every row of a download's menu runs its `browser.download.*` action on that download.
    @Test func aDownloadsMenuRowsRunTheirPaletteActions() throws {
        let list = BrowserDownloadList()
        let registry = Self.registry()
        BrowserToolbarHandlers.bindDownloads(into: registry, list: { list })
        let file = FileManager.default.temporaryDirectory.appending(path: "menu-rows-\(UUID().uuidString).pdf")
        list.add(.ended(sourceURL: URL(string: "https://example.com/report.pdf"), filename: "report.pdf", destination: file,
                        status: .finished, receivedBytes: 10, totalBytes: 10), tab: "tab-a") { _ in }
        let download = try #require(list.items.first)
        // The palette lists the download for the rows' `download` argument.
        let listed = registry.argumentSuggestions?(ActionSuggestions.browserDownloads) ?? []
        #expect(listed.map(\.value) == [download.id.uuidString])

        let recorders = BrowserToolbarHandlers.downloadActions.map { ($0, Recorder($0, in: registry)) }
        let menu = try #require(BrowserDownloadsMenu.actions(download, list: list, registry: registry))
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(rows.count == 3, "a finished web download offers Open, Show in Finder and Copy Download Link")
        for item in rows { _ = try #require(item.target as? NSObject).perform(try #require(item.action), with: item) }
        let ran = recorders.filter { !$0.1.runs.isEmpty }.map(\.0)
        #expect(ran == ["browser.download.open", "browser.download.reveal", "browser.download.copyLink"],
                "the rows did not run their palette actions: \(ran)")
        for (_, recorder) in recorders {
            #expect(recorder.runs.allSatisfy { $0["download"]?.stringValue == download.id.uuidString })
        }
    }

    // MARK: Back and Forward

    /// A Back menu row asks the tab's host for `browser.goToHistoryEntry`; that action (the palette's row, over the
    /// palette's list of entries) goes to the entry.
    @Test func aBackMenuRowRunsGoToHistoryEntry() throws {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://c.example")))
        tab.navigation = BrowserNavigationList(entries: [BrowserNavigationEntry(url: URL(string: "https://a.example"), title: "A"),
                                                         BrowserNavigationEntry(url: URL(string: "https://b.example"), title: ""),
                                                         BrowserNavigationEntry(url: URL(string: "https://c.example"), title: "C")],
                                               current: 2)
        final class Host: BrowserTabDelegate {
            var offsets: [Int] = []
            func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
                if case .goToHistoryEntry(let offset) = intent { offsets.append(offset) }
            }
        }
        let host = Host()
        tab.delegate = host
        let chrome = BrowserChromeView(tab: tab)
        let menu = try #require(chrome.backForwardMenu(forward: false))
        #expect(menu.items.map(\.title) == ["https://b.example", "A"])
        let row = try #require(menu.items.last)
        _ = try #require(row.target as? NSObject).perform(try #require(row.action), with: row)
        #expect(host.offsets == [-2], "the Back menu's row did not ask its host for Go Back or Forward to…")
        #expect(!tab.commands.contains(.goToEntry(-2)), "the row went there itself instead of through the action")

        let registry = Self.registry()
        BrowserToolbarHandlers.bindBackForward(into: registry, page: { _ in tab })
        let listed = registry.argumentSuggestions?(ActionSuggestions.browserBackForwardEntries) ?? []
        #expect(listed.map(\.value) == ["-1", "-2"])
        #expect(listed.map(\.title) == ["https://b.example", "A"])
        var invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: "tab-a"), arguments: ["entry": .string("-2")])
        invocation.keyContext = registry.context.union(.browserFocused)
        #expect(registry.perform("browser.goToHistoryEntry", invocation: invocation))
        #expect(tab.commands.contains(.goToEntry(-2)))
    }

    // MARK: Developer Tools

    /// The DevTools divider's rows are the palette's Developer Tools set: Dock to Left is its own command.
    @Test func theDividersDockRowsAreDeveloperToolsActions() {
        #expect(WebDevToolsCommand(actionID: "devtools.openDockedLeft") == .openDockedLeft)
        #expect(ActionCatalog.all.contains { $0.id == "devtools.openDockedLeft" })
        for dock in BrowserDevToolsDock.allCases {
            let command = CEFDevToolsDivider.command(for: dock)
            #expect(command.placement == .dock(dock), "\(dock): the row's action places DevTools elsewhere")
            #expect(ActionCatalog.all.contains { $0.id.rawValue == command.actionID }, "\(command.actionID) is no catalog action")
        }
        #expect(WebDevToolsCommand.close.placement == .close)
    }
}
