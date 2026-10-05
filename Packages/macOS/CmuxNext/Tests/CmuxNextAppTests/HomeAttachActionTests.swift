import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
@testable import CmuxNextHome
import Testing

/// `home.attachFiles` (palette "Attach Files…", `cmux home attach [path]`):
/// one cataloged action that hands files to the shown Home composer through
/// its own intake, or opens the file picker, or says why it cannot.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HomeAttachActionTests {
    @Test func theActionIsCatalogedForThePaletteAndTheCLI() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "home.attachFiles" })
        #expect(action.surfaces.contains(.palette))
        #expect(action.cliName == "home attach")
        #expect(action.arguments.map(\.name) == ["path"])
    }

    @Test func attachingAPathFromTheCLIMakesAChipInTheShownHome() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let window = try #require(harness.window.window)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("l16-action-\(UUID().uuidString)")
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: cache)
        let view = HomeNativeTranscriptView(conversation: ConversationID("conv_action"), me: ParticipantID("user_me"))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        let binding = HomeStoreBinding(store: store, controller: view.controller)
        defer { binding.stop() }
        view.connect(binding)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-plan.pdf")
        try Data("x".utf8).write(to: file)
        try await ViewChangePermissionTests.run(harness, "home.attachFiles", origin: "cli", arguments: ["path": .string(file.path)])
        await view.attachmentsReady()
        #expect(view.field.draftAttachments.map(\.ref.name) == [file.lastPathComponent], "the CLI's file is a chip")
    }

    @Test func withNoHomeShownTheActionRefuses() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let bridge = RegistryControlBridge(registry: harness.services.registry)
        let run = bridge.performActionTracked(ControlActionRequest(
            actionID: "home.attachFiles", target: nil, arguments: ["path": .string("/tmp/x.pdf")], origin: "cli", focus: false))
        guard case .refused = run.outcome else {
            Issue.record("home.attachFiles with no Home shown: \(run.outcome)")
            return
        }
    }
}
