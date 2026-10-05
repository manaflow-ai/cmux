import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite("Native sidebar selection transport")
struct SidebarNativeInteractionTests {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test(arguments: [
        CmuxSidebarSelectionModifiers(),
        CmuxSidebarSelectionModifiers(command: true),
        CmuxSidebarSelectionModifiers(shift: true),
        CmuxSidebarSelectionModifiers(command: true, shift: true)
    ])
    func modifierGesturesRoundTripWithoutSupplyingSelection(modifiers: CmuxSidebarSelectionModifiers) throws {
        let action = CmuxSidebarAction.selectWorkspaceRow(workspaceID: workspaceID, modifiers: modifiers)
        let restored = try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action))
        #expect(restored == action)
        #expect(restored.requiredScopes == [.selectWorkspace])
    }

    @Test
    @MainActor
    func selectionPermissionIsRequiredForModifierGestures() async {
        let host = CmuxSidebarHost(performAction: { action, reply in
            let grants: Set<CmuxExtensionActionScope> = []
            reply(action.requiredScopes.isSubset(of: grants) ? .accepted : .rejected("Selection denied"))
        })
        do {
            try await host.selectWorkspaceRow(workspaceID: workspaceID, modifiers: .init(command: true, shift: true))
            Issue.record("A modifier gesture must not bypass selection permission")
        } catch {
            #expect(error as? CmuxSidebarActionError == .rejected("Selection denied"))
        }
    }

    @Test
    @MainActor
    func nativeHelperUsesSharedReplyChannelAndPreservesModifiers() async throws {
        var requests: [CmuxSidebarAction] = []
        let host = CmuxSidebarHost(performAction: { action, reply in
            requests.append(action)
            reply(.accepted)
        })
        let modifiers = CmuxSidebarSelectionModifiers(command: true, shift: true)
        try await host.selectWorkspaceRow(workspaceID: workspaceID, modifiers: modifiers)
        #expect(requests == [.selectWorkspaceRow(workspaceID: workspaceID, modifiers: modifiers)])
    }

    @Test
    func nativePresentationRoundTripsWithOnlyItsExplicitScope() throws {
        let requests: [CmuxSidebarClassicMenuAction] = [
            .presentWorkspaceMenu(workspaceID: workspaceID, selectedWorkspaceIDs: [workspaceID]),
            .presentGroupMenu(groupID: workspaceID)
        ]
        for request in requests {
            let action = CmuxSidebarAction.classicMenu(request)
            #expect(try CmuxSidebarXPCCodec.decodeAction(CmuxSidebarXPCCodec.encodeAction(action)) == action)
            #expect(action.requiredScopes == [.presentNativeSidebarMenu])
        }
    }

    @Test
    @MainActor
    func grantingMutationScopesDoesNotGrantNativeMenuPresentation() async {
        let grants: Set<CmuxExtensionActionScope> = [.selectWorkspace, .closeWorkspace, .renameWorkspace]
        let host = CmuxSidebarHost(performAction: { action, reply in
            reply(action.requiredScopes.isSubset(of: grants) ? .accepted : .rejected("Menu denied"))
        })
        do {
            try await host.performClassicMenu(.presentWorkspaceMenu(workspaceID: workspaceID, selectedWorkspaceIDs: []))
            Issue.record("Mutation permissions must not imply native menu permission")
        } catch {
            #expect(error as? CmuxSidebarActionError == .rejected("Menu denied"))
        }
    }

    @Test
    func nativeMenuScopeRequiresMatchingHostVersion() {
        let manifest = CmuxExtensionManifest(id: "dev.example.native-menu", displayName: "Native Menu",
            actionScopes: [.presentNativeSidebarMenu], minimumAPIVersion: .sidebarV2_2)
        #expect(throws: CmuxExtensionValidationError.scopeRequiresAPIVersion(
            scope: "presentNativeSidebarMenu", required: .sidebarV2_3, declared: .sidebarV2_2)) {
            try validateSidebarManifest(manifest)
        }
    }
}
