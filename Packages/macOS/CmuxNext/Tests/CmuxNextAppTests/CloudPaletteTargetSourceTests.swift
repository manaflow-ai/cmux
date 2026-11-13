@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemonService
import CmuxNextDaemon
import Foundation
import Observation
import CmuxNextActions
import CmuxNextPalette
import Testing

@MainActor
struct CloudPaletteTargetSourceTests {
    @Observable private final class Inventory {
        var machines: [CloudMachine] = []
    }

    private final class EmptyTargets: PaletteTargetSource {
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { [] }
    }

    @Test func openPickerTracksStartingMachineUntilDesktopIsReady() async throws {
        let inventory = Inventory()
        inventory.machines = try [machine("new", desktop: false, status: "provisioning")]
        let source = CloudPaletteTargetSource(actions: ["cloudOpenDesktop"], next: EmptyTargets(),
            machines: { inventory.machines }, refresh: {},
            ask: { CloudHandlerRules().ask("cloud_handler_palette_targets", $0) })
        let updates = try #require(source.targetUpdates(of: .machine, for: "cloudOpenDesktop"))
        var iterator = updates().makeAsyncIterator()
        let starting = try #require(await iterator.next()?.first)
        #expect(!starting.isEnabled)
        inventory.machines = try [machine("new", desktop: true)]
        let ready = try #require(await iterator.next()?.first)
        #expect(ready.id == starting.id)
        #expect(ready.isEnabled)
        #expect(ready.recovery == nil)
    }

    private func machine(_ id: String, name: String? = nil, desktop: Bool, status: String = "running") throws -> CloudMachine {
        var record: [String: JSONValue] = ["id": .string(id), "desktop": .bool(desktop), "status": .string(status)]
        if let name { record["name"] = .string(name) }
        return try #require(CloudMachine(next: .object(record)))
    }

    private func options(machines: [CloudMachine], desktop: Bool) -> [CmuxNextPalette.PaletteTargetOption] {
        CloudPaletteTargetSource.options(machines: machines, desktop: desktop) {
            CloudHandlerRules().ask("cloud_handler_palette_targets", $0)
        }
    }

    @Test func readyMachinesComeBeforeOlderImagesAndPausedMachinesOfferResume() throws {
        let machines = try [machine("old", desktop: false), machine("paused", desktop: true, status: "paused"),
                            machine("ready", desktop: true)]
        let rows = options(machines: machines, desktop: true)
        #expect(Set(rows.prefix(2).map(\.id)) == ["paused", "ready"])
        let old = try #require(rows.first { $0.id == "old" })
        #expect(old.subtitle?.isEmpty == false)
        #expect(old.recovery?.action == "newCloudMachine")
        #expect(old.isEnabled, "the repair is actionable in the same row")
        let paused = try #require(rows.first { $0.id == "paused" })
        #expect(paused.accessory?.isEmpty == false)
        #expect(paused.recovery == nil, "resume runs Open Desktop on this machine")
        #expect(paused.isEnabled)
    }

    @Test func unnamedMachinesNeverShowTheirIDsOrCLIInstructions() throws {
        let rows = options(machines: try [machine("private-machine-id", desktop: false)], desktop: true)
        let row = try #require(rows.first)
        let visible = [row.title, row.subtitle ?? "", row.accessory ?? "", row.recovery?.title ?? ""].joined(separator: " ")
        #expect(!visible.contains("private-machine-id"))
        #expect(!visible.contains("machine:"))
        #expect(!visible.contains("cmux cloud"))
    }

    @Test func emptyAccountOffersCreatingADesktop() throws {
        let row = try #require(options(machines: [], desktop: true).first)
        #expect(row.recovery?.action == "newCloudMachine")
        #expect(row.isEnabled)
    }

    @Test func otherCloudActionsIncludeMachinesWithoutDesktop() throws {
        let rows = options(machines: try [machine("old", desktop: false)], desktop: false)
        let row = try #require(rows.first)
        #expect(row.isEnabled)
        #expect(row.recovery == nil)
    }
}
