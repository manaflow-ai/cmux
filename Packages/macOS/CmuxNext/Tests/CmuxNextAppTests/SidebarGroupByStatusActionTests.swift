import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Group ▸ Group by Status (`sidebar.groupBy.status`) is a Labs action: with
/// `labs.sidebarStatusGrouping` off it says to turn the flag on instead of saving a value the
/// sidebar would read as no grouping; with the flag on it runs like Group by Folder.
@MainActor @Suite(.serialized)
struct SidebarGroupByStatusActionTests {
    private static func services(_ json: String) async throws -> (AppServices, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-groupby-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.settings = settings
        AppActions.bind(services)
        return (services, directory)
    }

    @Test func groupByStatusWaitsForItsLabsFlag() async throws {
        let (services, directory) = try await Self.services("{}")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(services.registry.descriptor(for: "sidebar.groupBy.status") != nil)
        #expect(services.registry.unavailableReason(for: "sidebar.groupBy.status") != nil)
    }

    @Test func groupByStatusRunsWithItsLabsFlagOn() async throws {
        let (services, directory) = try await Self.services(#"{"labs":{"sidebarStatusGrouping":true}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(services.registry.unavailableReason(for: "sidebar.groupBy.status") == nil)
        #expect(services.registry.unavailableReason(for: "sidebar.groupBy.folder") == nil)
    }

    @Test func groupByStatusIsUnavailableWhenTheListIsAlreadyGroupedByStatus() async throws {
        let (services, directory) = try await Self.services(#"{"labs":{"sidebarStatusGrouping":true},"sidebar":{"groupBy":"status"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(services.settings?.snapshot.sidebarSections.groupBy == .status)
        #expect(services.registry.unavailableReason(for: "sidebar.groupBy.status") != nil)
        #expect(services.registry.unavailableReason(for: "sidebar.groupBy.none") == nil)
    }
}
