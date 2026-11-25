import Foundation
import Testing
@testable import CmuxMobileModel
@testable import CmuxMobileSettings

@MainActor
@Suite struct SettingsDeviceListTests {
    private final class Directory: SettingsDeviceDirectory {
        var result: Result<[SettingsDevice], URLError>
        var relayAvailable: Bool? { nil }

        init(_ rows: [SettingsDevice]) { result = .success(rows) }
        func devices() async throws -> [SettingsDevice] { try result.get() }
        func remove(_ device: SettingsDevice) async throws {}
        func deleteAccountData() async throws {}
        func removeThisPhoneFromMacs() async {}
    }

    @Test func directorySurvivesRelaunchAndOfflineRefreshAndKeepsAnEmptyAnswer() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = LastKnownListStore(directory: folder)
        let mac = SettingsDevice(ids: ["mac"], kind: .mac, name: "My Mac", online: true, lastSeenAt: nil,
                                 isThisDevice: false, receivesNotifications: false)
        let directory = Directory([mac])
        let original = SettingsDeviceList(cache: first.list(accountID: "me", screen: "devices"))
        #expect(original.devices == nil)
        await original.load(directory)
        first.flush()

        let reopened = LastKnownListStore(directory: folder)
        let handle = reopened.list(accountID: "me", screen: "devices")
        let list = SettingsDeviceList(cache: handle)
        #expect(list.devices == [mac])
        #expect(SettingsDeviceList(cache: reopened.list(accountID: "other", screen: "devices")).devices == nil)
        directory.result = .failure(URLError(.notConnectedToInternet))
        await list.load(directory)
        #expect(list.devices == [mac])
        #expect(list.loadError != nil)

        directory.result = .success([])
        await list.load(directory)
        #expect(list.loadError == nil)
        reopened.flush()
        let cold = LastKnownListStore(directory: folder)
        #expect(SettingsDeviceList(cache: cold.list(accountID: "me", screen: "devices")).devices == [])
    }

    @Test func removalImmediatelyUpdatesTheKeptRoster() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = LastKnownListStore(directory: folder)
        defer {
            store.flush()
            try? FileManager.default.removeItem(at: folder)
        }
        let cache = store.list(accountID: "me", screen: "devices")
        let device = SettingsDevice(ids: ["phone", "presence"], kind: .phone, name: "Old iPhone", online: nil,
                                    lastSeenAt: nil, isThisDevice: false, receivesNotifications: false)
        let list = SettingsDeviceList(cache: cache)
        await list.load(Directory([device]))
        list.removed(device)
        #expect(SettingsDeviceList(cache: cache).devices == [])
    }
}
