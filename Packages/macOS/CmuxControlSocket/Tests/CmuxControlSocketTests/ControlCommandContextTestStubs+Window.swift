import Foundation
@testable import CmuxControlSocket

// Benign window-domain defaults; see ControlCommandContextTestStubs.swift.

extension ControlWindowContext {
    func controlWindowSummaries() -> [ControlWindowSummary] { [] }
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        .tabManagerUnavailable
    }
    func controlFocusWindow(id: UUID) -> Bool { false }
    func controlCreateWindowAndActivate() -> UUID? { nil }
    func controlCloseWindow(id: UUID) -> Bool { false }
    func controlAvailableDisplays() -> [ControlDisplayInfo] { [] }
    func controlWindowExists(id: UUID) -> Bool { false }
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? { nil }
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? { nil }

    func controlCurrentWindowV1() -> String { "" }
    func controlFocusWindowV1(arg: String) -> String { "" }
    func controlNewWindowV1() -> String { "" }
    func controlCloseWindowV1(arg: String) -> String { "" }
    func controlMoveWorkspaceToWindowV1(args: String) -> String { "" }
}
