import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// SECURITY (agent_settable): a palette setting action run from the socket (origin cli) cannot
/// change a user-only key; the same action from the user's own palette can.
@MainActor @Suite(.serialized) struct PaletteSettingWriterTests {
    @Test func aSocketRunOfASettingActionCannotChangeAUserOnlyKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "palette-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        let arguments: [String: ActionValue] = ["setting": .string("history.terminalCommands"), "on": .bool(false)]
        services.registry.perform("palette.toggleSetting", invocation: ActionInvocation(arguments: arguments, origin: .cli))
        for _ in 0..<300 { await Task.yield() }
        #expect(settings.validatedWrites["history.terminalCommands", default: 0] == 0, "a cli run wrote a user-only key")
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == nil)
        services.registry.perform("palette.toggleSetting", invocation: ActionInvocation(arguments: arguments, origin: .user))
        for _ in 0..<300 where settings.validatedWrites["history.terminalCommands", default: 0] == 0 { await Task.yield() }
        #expect(try await settings.file.value(at: ["history", "terminalCommands"]) == .bool(false))
    }
}
