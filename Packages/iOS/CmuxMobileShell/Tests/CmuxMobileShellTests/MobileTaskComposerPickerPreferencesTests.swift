import Foundation
import Testing
import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel

@MainActor
struct MobileTaskComposerPickerPreferencesTests {
    @Test(.timeLimit(.minutes(1))) func corruptedPickerPreferencesAreDroppedAndDiagnosed() async throws {
        let suite = "MobileTaskComposerPickerPreferencesTests.corrupt.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let attachmentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-preferences-corrupt-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog(capacity: 8)
        let (events, continuation) = AsyncStream<DiagnosticEvent>.makeStream()
        log.setEventTap { continuation.yield($0) }
        defer {
            log.setEventTap(nil)
            continuation.finish()
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: attachmentRoot) }
        let store = UserDefaultsMobileTaskTemplateStore(
            defaults: defaults,
            diagnosticLog: log,
            attachmentFilesRootDirectory: attachmentRoot
        )
        let pairingID = MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly")
        defaults.set(
            Data("not-a-picker-payload".utf8),
            forKey: "cmux.mobile.taskComposer.pickers.v1.\(pairingID)"
        )

        #expect(store.composerPickerPreferences(macPairingID: pairingID) == nil)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.a == DiagnosticAppEventKind.templatePersistenceFailed.rawValue)
        #expect(event?.b == DiagnosticFailureKind.protocolViolation.rawValue)
    }

    @Test func remembersEveryPickerAcrossRelaunchAndKeepsMacInstancesSeparate() throws {
        let suite = "MobileTaskComposerPickerPreferencesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let attachmentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-preferences-\(UUID().uuidString)", isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { try? FileManager.default.removeItem(at: attachmentRoot) }
        let store = UserDefaultsMobileTaskTemplateStore(
            defaults: defaults,
            attachmentFilesRootDirectory: attachmentRoot
        )
        let templateID = try #require(store.listTemplates().first?.id)
        let model = MobileTaskAgentModel(
            id: "selected-model", displayName: "Selected model",
            efforts: [.init(id: "high", displayName: "High")], defaultEffortID: "high"
        )
        let first = MobileTaskComposerPickerPreferences(
            templateID: templateID, model: model, defaultModel: model,
            effortID: "high", directory: "~/first", didEditDirectory: true,
            workspaceGroupID: "first-group"
        )
        let second = MobileTaskComposerPickerPreferences(
            templateID: templateID, model: nil, defaultModel: model,
            effortID: "high", directory: "~/second", didEditDirectory: true,
            workspaceGroupID: nil
        )
        let stable = MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "default")
        let nightly = MobilePairedMac.pairingID(macDeviceID: "mac-a", instanceTag: "nightly")
        let other = MobilePairedMac.pairingID(macDeviceID: "mac-b", instanceTag: "default")
        store.setComposerPickerPreferences(first, macPairingID: stable)
        store.setComposerPickerPreferences(second, macPairingID: nightly)
        store.setLastMacDeviceID("mac-a")
        store.setLastMacPairingID(nightly)

        let reloaded = UserDefaultsMobileTaskTemplateStore(
            defaults: defaults,
            attachmentFilesRootDirectory: attachmentRoot
        )
        #expect(reloaded.composerPickerPreferences(macPairingID: stable) == first)
        #expect(reloaded.composerPickerPreferences(macPairingID: nightly) == second)
        #expect(reloaded.composerPickerPreferences(macPairingID: other) == nil)
        // Explicit Default and None must survive, including Default's effort metadata.
        #expect(reloaded.composerPickerPreferences(macPairingID: nightly)?.model == nil)
        #expect(reloaded.composerPickerPreferences(macPairingID: nightly)?.defaultModel?.efforts == model.efforts)
        #expect(reloaded.lastMacDeviceID() == "mac-a")
        #expect(reloaded.lastMacPairingID() == nightly)

        reloaded.clearAllUserData()
        #expect(store.composerPickerPreferences(macPairingID: stable) == nil)
        #expect(store.composerPickerPreferences(macPairingID: nightly) == nil)
        #expect(store.lastMacDeviceID() == nil)
        #expect(store.lastMacPairingID() == nil)
    }
}
