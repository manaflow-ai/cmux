import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// `debug.cloud_machine_fixture` (captures of a Cloud machine's right-click menu): signed out and with
/// no Cloud machine, as on a capture slot, the header's menu hides the Tools folder's Apply Machine
/// Config and Deliver Secrets; the fixture shows them with no session or sign-in, and it exists in
/// DEBUG builds only.
@MainActor @Suite(.serialized)
struct DebugCloudMachineFixtureTests {
    #if DEBUG
    static let toolsRows: Set<ActionID> = ["cloudApplyMachineConfig", "cloudDeliverSecrets"]

    /// The rows the fixture machine's header menu runs, by folder title ("" for the top level).
    static func rows(_ services: AppServices) -> [String: Set<ActionID>] {
        var rows: [String: Set<ActionID>] = [:]
        func walk(_ items: [NSMenuItem], _ folder: String) {
            for item in items {
                if let id = ActionRegistry.menuRun(of: item)?.id { rows[folder, default: []].insert(id) }
                if let submenu = item.submenu { walk(submenu.items, item.title) }
            }
        }
        walk(SidebarContextMenus.machineMenu(DebugCloudMachineFixture.defaultName, services: services).items, "")
        return rows
    }

    @Test func theFixtureShowsTheToolsRowsTheHeaderMenuHidesWithoutIt() {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        services.cloudContextDidChange()
        #expect(!services.registry.context.contains(.cloudWorkspace), "signed out, with no Cloud machine")
        #expect(Self.rows(services).values.allSatisfy { $0.isDisjoint(with: Self.toolsRows) }, "the rows are hidden without the fixture")

        DebugCloudMachineFixture.seed(services)
        defer { DebugCloudMachineFixture.seed(services, false) }
        #expect(services.registry.context.contains(.cloudWorkspace))
        #expect(!services.cloud.isSignedIn, "no sign-in")
        #expect(services.machines.cloud.isEmpty, "no Cloud session")
        #expect(Self.rows(services)[MenuFolder.tools.title, default: []].isSuperset(of: Self.toolsRows),
                "both rows show in the header menu's Tools folder")
        let other = MachineIconTests.services()
        other.cloudContextDidChange()
        #expect(!other.registry.context.contains(.cloudWorkspace), "another app's services never hold it")

        DebugCloudMachineFixture.seed(services, false)
        #expect(!services.registry.context.contains(.cloudWorkspace))
        #expect(Self.rows(services).values.allSatisfy { $0.isDisjoint(with: Self.toolsRows) }, "off, the rows hide again")
    }
    #endif

    /// The fixture, its route and the context it adds compile in DEBUG builds only, so a Release build
    /// never holds `cloudWorkspace` without a Cloud machine (the isolated Release compile builds
    /// without them).
    @Test func theFixtureIsDebugOnly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CmuxNextApp")
        let fixture = try String(contentsOf: sources.appendingPathComponent("Control/DebugCloudMachineFixture.swift"), encoding: .utf8)
        #expect(fixture.hasPrefix("#if DEBUG\n"))
        #expect(fixture.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        for file in ["Cloud/AppServices+Cloud.swift", "Control/AppControl.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            var depth: [Bool] = [] // per open #if: whether it is DEBUG only
            var uses = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("#if ") {
                    depth.append(line == "#if DEBUG")
                } else if line.hasPrefix("#else") || line.hasPrefix("#elseif"), !depth.isEmpty {
                    depth[depth.count - 1] = false // the other branch of a DEBUG-only #if is not DEBUG only
                } else if line == "#endif" {
                    _ = depth.popLast()
                }
                guard line.contains("DebugCloudMachineFixture") || line.contains("debug.cloud_machine_fixture") else { continue }
                uses += 1
                #expect(depth.contains(true), "\(file): \(line) is outside #if DEBUG")
            }
            #expect(uses > 0, "\(file) uses the fixture")
        }
    }
}
