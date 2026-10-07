import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// Rooms became Spaces (data-model.md 3.4). The new names are the only
/// ones shown, and every old name still reaches the same action: action
/// ids through the legacy aliases, CLI names and the `room` noun through
/// `ControlCatalog.renamedCLIName`.
@MainActor
@Suite struct SpacesRenameTests {
    static let catalog = RegistryControlBridge.catalog(from: ActionRegistry.standard())

    @Test func noActionIDOrCLINameSaysRoom() {
        for action in Self.catalog.actions {
            #expect(!action.id.lowercased().contains("room"), "\(action.id)")
            #expect(!action.cliName.contains("room"), "\(action.cliName)")
        }
    }

    @Test func oldActionIDsResolveToTheSpaceActions() throws {
        for (old, new) in [("room.new", "space.new"), ("room.next", "space.next"), ("workspace.moveToRoom", "workspace.moveToSpace"),
                           ("browserProfile.setRoomDefault", "browserProfile.setSpaceDefault")] {
            #expect(try #require(Self.catalog.resolve(old)).id == new)
        }
    }

    @Test func oldCLINamesResolveToTheSpaceActions() throws {
        for (old, new) in [("room create", "space.new"), ("room  switch", "space.switch"), ("workspace move-to-room", "workspace.moveToSpace"),
                           ("browser-profile set-room-default", "browserProfile.setSpaceDefault")] {
            #expect(try #require(Self.catalog.resolve(old)).id == new)
        }
        #expect(Self.catalog.resolve("roomy create") == nil)
    }

    @Test func theRoomNounListsTheSpaceActions() throws {
        let old = ControlRouter.list(["noun": "room"], catalog: Self.catalog)
        let new = ControlRouter.list(["noun": "space"], catalog: Self.catalog)
        let count = try #require(new["count"]?.intValue)
        #expect(count > 10)
        #expect(old["count"]?.intValue == count)
    }

    /// Old scripts pass `--room`; it reaches the `space` argument.
    @Test func theOldRoomArgumentStillValidates() throws {
        let action = try #require(Self.catalog.resolve("workspace move-to-room"))
        let request = try ControlRouter.validatedRequest(for: action, params: ["args": .object(["room": .string("Work")])], knownKinds: [],
                                                         connection: .inProcess)
        #expect(request.arguments["space"] != nil)
        #expect(request.arguments["room"] == nil)
    }

    @Test func theSpaceArgumentReplacesRoom() throws {
        let rename = try #require(Self.catalog.resolve("space.newWorkspace"))
        #expect(rename.arguments.contains { $0.name == "space" })
        #expect(!rename.arguments.contains { $0.name == "room" })
    }
}
