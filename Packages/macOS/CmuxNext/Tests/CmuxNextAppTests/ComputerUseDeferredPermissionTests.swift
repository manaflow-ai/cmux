import Darwin
import Foundation
import Testing
@testable import CmuxNextComputerUse

@MainActor struct ComputerUseDeferredPermissionTests {
    @Test(arguments: [false, true])
    func setupClickWaitsForReadyAndTurningOffCancelsIt(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cu-grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = Pipe()
        let descriptor = dup(pipe.fileHandleForWriting.fileDescriptor)
        try #require(descriptor >= 0)
        try pipe.fileHandleForWriting.close()
        let lines = AsyncStream<Data> { continuation in
            continuation.yield(ComputerUseHelperV2.line(["type": "ready", "protocol": 1,
                                                        "socket": directory.path + "/h.sock"]))
            continuation.finish()
        }
        let child = ComputerUseHelperV2Child(pid: getpid(), input: descriptor, lines: lines)
        let helper = ComputerUseHelperV2(directory: directory.path, helperApp: { URL(fileURLWithPath: "/test/Helper.app") },
                                        acpmux: { nil }, staging: .passing(root: directory),
                                        spawner: PermissionTestSpawner(child: child))

        // A click can arrive while enabling is still being applied. Merely
        // starting the helper after cancellation must never replay that click.
        await helper.requestPermission(screenRecording: false)
        if cancel { await helper.apply(enabled: false) }
        await helper.apply(enabled: true)
        helper.terminateForQuit()
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        let messages = try data.split(separator: 10).map {
            let object = try JSONSerialization.jsonObject(with: Data($0))
            return try #require(object as? [String: Any])
        }
        #expect(messages.first?["type"] as? String == "configure")
        let grants = messages.filter { $0["type"] as? String == "request_permission" }
        #expect(grants.count == (cancel ? 0 : 1))
        if !cancel { #expect(grants.first?["permission"] as? String == "accessibility") }
    }
}

private struct PermissionTestSpawner: ComputerUseHelperV2Spawning {
    let child: ComputerUseHelperV2Child
    func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child { child }
    func terminate(_ pid: pid_t) {}
    @MainActor func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void { {} }
}
