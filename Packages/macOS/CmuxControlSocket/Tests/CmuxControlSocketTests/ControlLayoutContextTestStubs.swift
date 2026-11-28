import Foundation
@testable import CmuxControlSocket

extension ControlLayoutContext {
    func controlLayoutSave(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        name: String,
        description: String?,
        overwrite: Bool
    ) -> ControlLayoutSaveResolution { .workspaceNotFound }

    func controlLayoutList() -> ControlLayoutListResolution { .resolved([]) }

    func controlLayoutGet(name: String) -> ControlLayoutGetResolution { .notFound }

    func controlLayoutOpen(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        focusRequested: Bool
    ) -> ControlLayoutOpenResolution { .tabManagerUnavailable }

    func controlLayoutDelete(name: String) -> ControlLayoutDeleteResolution { .notFound }
}
