import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
import CmuxNextWakeups

/// Password export is off until the person turns it on (cmux-next-spec
/// PASSWORDS P3, cx-d0d.13): with a store that can export and a person who
/// would approve every sheet, the page's export is refused before any
/// confirmation, authentication or save panel.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PasswordExportOffTests {
    @MainActor final class Approver: PageConfirmationPresenter, DeviceOwnerAuthenticating, PasswordSecretSurface {
        var asked: [String] = []
        let destination: URL

        init(destination: URL) { self.destination = destination }

        func confirm(_ confirmation: PageConfirmation, anchor: NSView?) async -> Bool {
            asked.append("confirm")
            return true
        }

        func authenticate(reason: String) async -> Bool {
            asked.append("authenticate")
            return true
        }

        func reveal(_ secret: SecretBytes, site: String, username: String, anchor: NSView?) async {}

        func copy(_ secret: SecretBytes) {}

        func exportDestination(profileName: String, anchor: NSView?) async -> URL? {
            asked.append("destination")
            return destination
        }
    }

    @Test func exportIsRefusedByDefaultBeforeAnySheet() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "cn-export-off-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: destination) }
        let store = SamplePasswordStore()
        let person = Approver(destination: destination)
        let provider = PasswordsPageProvider(store: store, profiles: { [.init(id: "default", name: "Default")] },
                                             confirmations: person, authenticator: person, secrets: person,
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))

        var refusal: PageError?
        do {
            _ = try await provider.call(PasswordOps.export, params: ["profile": "default"],
                                        context: PageCallContext(page: "cmux.passwords", userGesture: true))
        } catch let error as PageError {
            refusal = error
        }
        #expect(refusal?.code == PasswordOps.unavailableCode)
        #expect(person.asked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    final class Events {
        var received: [JSONValue] = []
    }

    /// With the page open, turning export on in Settings tells the page (its `changed` stream), so
    /// the disabled Export button comes back without a reopen; the export then asks the person
    /// and writes the file (#20058 review).
    @Test func turningExportOnReachesAnOpenPageAndExports() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-export-on-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: file)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let destination = home.appending(path: "passwords.csv")
        let person = Approver(destination: destination)
        let provider = PasswordsPageProvider(store: SamplePasswordStore(), profiles: { [.init(id: "default", name: "Default")] },
                                             confirmations: person, authenticator: person, secrets: person,
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        provider.allowExport = { BrowserPasswordsSetting.current(settings).allowExport }
        let context = PageCallContext(page: "cmux.passwords", userGesture: true)
        let events = Events()
        let subscription = try await provider.subscribe(PasswordOps.changed, filter: .null, context: context) { events.received.append($0) }
        defer { subscription.cancel() }

        try await settings.setSetting(at: BrowserPasswordsSetting.allowExportPath, to: .bool(true), by: .user)
        for _ in 0..<60 where events.received.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!events.received.isEmpty)

        _ = try await provider.call(PasswordOps.export, params: ["profile": "default"], context: context)
        #expect(person.asked == ["confirm", "authenticate", "destination"])
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}
