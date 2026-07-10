import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugAndroidEmulatorControlCommandContext: ControlCommandContext {
    var didShowAndroidEmulators = false

    func controlDebugShowAndroidEmulators() {
        didShowAndroidEmulators = true
    }
}

@MainActor
@Suite("ControlCommandCoordinator Android emulator debug dispatch")
struct ControlCommandCoordinatorDebugAndroidEmulatorTests {
    @Test func showAndroidEmulatorsInvokesSharedAppAction() {
        let context = FakeDebugAndroidEmulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(
            id: .int(1),
            method: "debug.android_emulators.show",
            params: [:]
        )

        let result = coordinator.handle(request)

        #expect(result == .ok(.object(["shown": .bool(true)])))
        #expect(context.didShowAndroidEmulators)
    }
}
#endif
