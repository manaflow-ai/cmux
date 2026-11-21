import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextPalette
import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Foundation
import Testing

/// Lawrence 2026-11-16: "we need cmd shift p restart to update". While a downloaded update waits,
/// Cmd-Shift-P lists Restart to Update, found by restart, update, relaunch or upgrade, and running it
/// runs the install the sidebar card's Restart to Update runs (`palette.applyUpdateIfAvailable`).
/// With no update waiting there is no such row, and Check for Updates… is listed instead.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)))
struct UpdatePaletteRowsTests {
    static let rowID = RestartToUpdatePaletteRows.rowID

    /// A palette wired as the App wires it, over `updater`; `installs` records each install run.
    @MainActor final class Harness {
        let palette: PaletteController
        let registry: ActionRegistry
        var installs: [ActionInvocation] = []

        init(updater: UpdaterService) {
            _ = NSApplication.shared
            registry = ActionRegistry.standard()
            palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
            palette.bindRegistryActions()
            for id: ActionID in ["palette.checkForUpdates", "palette.attemptUpdate"] {
                registry.bindEffect(id) { _ in .done }
            }
            registry.bindEffect("palette.applyUpdateIfAvailable") { [unowned self] invocation in
                installs.append(invocation)
                return .done
            }
            RestartToUpdatePaletteRows(staged: { [weak updater] in updater?.restartableUpdate.map { ($0.title, $0.version) } })
                .install(into: palette, registry: registry)
        }

        /// Hides the palette and closes its panel (`hide()` only orders the reused panel out).
        func closePanels() {
            palette.hide()
            for window in NSApp?.windows ?? [] where palette.owns(window) {
                window.isReleasedWhenClosed = false
                window.close()
            }
        }

        /// The rows Cmd-Shift-P shows for `query`, best first.
        func rows(_ query: String) async -> [PaletteRow] {
            _ = registry.perform("commandPalette", invocation: ActionInvocation(arguments: [:], origin: .user))
            await palette.model.settleDeferredLoads()
            palette.model.send(.setQuery(query))
            await palette.model.settle()
            for _ in 0..<200 where palette.model.rows.isEmpty { await Task.yield() }
            return palette.model.rows
        }
    }

    /// An updater with a downloaded update waiting (Sparkle's Update Ready), or none.
    static func updater(staged: Bool) -> UpdaterService {
        let updater = UpdateActionResultTests.updater(nil)
        if staged { _ = updater.flow.handle(.sparkle(.ready(version: "1.1.0")), preferences: .defaults) }
        return updater
    }

    @Test func aWaitingUpdateIsRestartable() {
        #expect(Self.updater(staged: false).restartableUpdate == nil)
        #expect(Self.updater(staged: true).restartableUpdate == RestartableUpdate(version: "1.1.0"))
    }

    @Test(arguments: ["restart to update", "restart", "relaunch", "upgrade", "update"])
    func cmdShiftPFindsRestartToUpdateWhileAnUpdateWaits(query: String) async throws {
        let updater = Self.updater(staged: true)
        let harness = Harness(updater: updater)
        defer { harness.closePanels() }
        let ids = await harness.rows(query).map(\.item.id)
        let at = try #require(ids.firstIndex(of: Self.rowID), "\(query): \(ids.prefix(12))")
        #expect(at < 3, "\(query): \(ids.prefix(12))")
        if query == "restart to update" { #expect(at == 0, "\(ids.prefix(12))") }
        #expect(!ids.contains("action:palette.checkForUpdates"), "a check only answers with the waiting update: \(ids.prefix(12))")
    }

    @Test func theRowIsTitledAsTheSidebarCardsButtonAndRunsItsInstall() async throws {
        let updater = Self.updater(staged: true)
        let harness = Harness(updater: updater)
        defer { harness.closePanels() }
        let row = try #require(await harness.rows("restart to update").first { $0.item.id == Self.rowID })
        #expect(row.item.title == UpdaterStrings.restartToUpdate)
        #expect(row.item.subtitle == "1.1.0")
        harness.palette.model.run(row.item.primary, of: row.item)
        #expect(harness.installs.count == 1)
        #expect(harness.installs.first?.origin == .user)
    }

    @Test func withNoUpdateWaitingCheckForUpdatesIsListedInstead() async throws {
        let harness = Harness(updater: Self.updater(staged: false))
        defer { harness.closePanels() }
        let ids = await harness.rows("update").map(\.item.id)
        #expect(!ids.contains(Self.rowID), "\(ids.prefix(12))")
        #expect(ids.contains("action:palette.checkForUpdates"), "\(ids.prefix(12))")
    }
}
