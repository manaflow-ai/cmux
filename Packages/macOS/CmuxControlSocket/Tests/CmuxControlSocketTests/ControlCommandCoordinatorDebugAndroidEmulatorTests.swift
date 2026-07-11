import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
@MainActor
private final class FakeDebugAndroidEmulatorControlCommandContext: ControlCommandContext {
    var didShowAndroidEmulators = false
    var didOpenRunningAndroidEmulator = false

    func controlDebugShowAndroidEmulators() {
        didShowAndroidEmulators = true
    }

    func controlDebugOpenRunningAndroidEmulator() -> Bool {
        didOpenRunningAndroidEmulator = true
        return true
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

    @Test func openRunningAndroidEmulatorInvokesSharedAppAction() {
        let context = FakeDebugAndroidEmulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(
            id: .int(2),
            method: "debug.android_emulators.open_running",
            params: [:]
        )

        let result = coordinator.handle(request)

        #expect(result == .ok(.object(["opened": .bool(true)])))
        #expect(context.didOpenRunningAndroidEmulator)
    }
}
#endif
