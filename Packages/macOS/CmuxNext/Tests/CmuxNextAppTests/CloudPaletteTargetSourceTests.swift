@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

@MainActor
struct CloudPaletteTargetSourceTests {
    private func machine(_ id: String, name: String? = nil, desktop: Bool, status: String = "running") throws -> CloudMachine {
        var record: [String: JSONValue] = ["id": .string(id), "desktop": .bool(desktop), "status": .string(status)]
        if let name { record["name"] = .string(name) }
        return try #require(CloudMachine(next: .object(record)))
    }

    @Test func readyMachinesComeBeforeOlderImagesAndPausedMachinesOfferResume() throws {
        let machines = try [machine("old", desktop: false), machine("paused", desktop: true, status: "paused"),
                            machine("ready", desktop: true)]
        let rows = CloudPaletteTargetSource.options(machines: machines, desktop: true)
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
        let rows = CloudPaletteTargetSource.options(machines: try [machine("private-machine-id", desktop: false)], desktop: true)
        let row = try #require(rows.first)
        let visible = [row.title, row.subtitle ?? "", row.accessory ?? "", row.recovery?.title ?? ""].joined(separator: " ")
        #expect(!visible.contains("private-machine-id"))
        #expect(!visible.contains("machine:"))
        #expect(!visible.contains("cmux cloud"))
    }

    @Test func emptyAccountOffersCreatingADesktop() throws {
        let row = try #require(CloudPaletteTargetSource.options(machines: [], desktop: true).first)
        #expect(row.recovery?.action == "newCloudMachine")
        #expect(row.isEnabled)
    }

    @Test func otherCloudActionsIncludeMachinesWithoutDesktop() throws {
        let rows = CloudPaletteTargetSource.options(machines: try [machine("old", desktop: false)], desktop: false)
        let row = try #require(rows.first)
        #expect(row.isEnabled)
        #expect(row.recovery == nil)
    }
}
