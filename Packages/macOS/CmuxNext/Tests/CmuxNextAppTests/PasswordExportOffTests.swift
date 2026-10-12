import AppKit
@testable import CmuxNextApp
import CmuxNextBrowserImport
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

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
                                             confirmations: person, authenticator: person, secrets: person)

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
}
