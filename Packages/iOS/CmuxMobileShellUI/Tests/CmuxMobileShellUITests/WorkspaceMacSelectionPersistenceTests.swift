import CmuxMobileShellModel
import CmuxMobilePairedMac
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileShellUI

@MainActor
struct WorkspaceMacSelectionPersistenceTests {
    @Test(arguments: [
        WorkspaceMacSelection.all,
        .automatic,
        .machine("mac-a"),
        .machine(MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly")),
    ])
    func restoresSelectionFromFreshPreferences(selection: WorkspaceMacSelection) throws {
        let suite = "WorkspaceMacSelectionPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: defaults
        )
        storage.wrappedValue = selection

        let restored = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: try #require(UserDefaults(suiteName: suite))
        )
        #expect(restored.wrappedValue == selection)
    }

    @Test func allComputersReplacesPreviousMachineSelection() throws {
        let suite = "WorkspaceMacSelectionPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: defaults
        )
        storage.wrappedValue = .machine("mac-a")
        storage.wrappedValue = .all

        let restored = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: try #require(UserDefaults(suiteName: suite))
        )
        #expect(restored.wrappedValue == .all)
    }

    @Test(arguments: [nil, "", "unknown", "machine:"] as [String?])
    func missingOrInvalidPreferenceDefaultsToAllComputers(rawValue: String?) throws {
        let suite = "WorkspaceMacSelectionPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(rawValue, forKey: WorkspaceMacSelection.storageKey)

        let storage = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: defaults
        )
        #expect(storage.wrappedValue == .all)
    }

    @Test func discoveryDoesNotDiscardRememberedSelection() throws {
        let suite = "WorkspaceMacSelectionPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AppStorage(
            wrappedValue: WorkspaceMacSelection.all,
            WorkspaceMacSelection.storageKey,
            store: defaults
        )
        storage.wrappedValue = .machine("mac-a")

        func scope(foregroundMacDeviceID: String?) -> WorkspaceMacSelectionScope {
            WorkspaceMacSelectionScope(
                selection: storage.wrappedValue,
                workspaces: [],
                displayPairedMacs: [],
                foregroundMacDeviceID: foregroundMacDeviceID,
                aliasesFor: { _ in [] }
            )
        }
        #expect(scope(foregroundMacDeviceID: nil).visibleSelection == .all)
        #expect(storage.wrappedValue == .machine("mac-a"))
        #expect(scope(foregroundMacDeviceID: "mac-a").visibleSelection == .machine("mac-a"))
    }
}
