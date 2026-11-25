// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

struct HelperPermissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: [HelperPermission.accessibility, .screenRecording])
    func hostRequestsOnlyTheChosenPermission(_ permission: HelperPermission) async throws {
        let input = Pipe(), output = Pipe()
        let line = try JSONSerialization.data(withJSONObject: ["type": "request_permission", "permission": permission.rawValue])
        try input.fileHandleForWriting.write(contentsOf: line + Data([10]))
        try input.fileHandleForWriting.close()
        let requested = await withCheckedContinuation { continuation in
            let controller = HelperController(
                input: input.fileHandleForReading.fileDescriptor,
                output: output.fileHandleForWriting.fileDescriptor,
                tools: UnavailableTools(reason: "test"),
                requestPermission: { grant in
                    continuation.resume(returning: grant)
                    return false
                },
                onExit: { _ in }
            )
            controller.start()
        }
        #expect(requested == permission)
        // A pipe stays open for the helper's lifetime. Foundation's
        // read(upToCount:) may wait to fill the buffer; read the available
        // acknowledgement off the cooperative executor instead.
        let descriptor = output.fileHandleForReading.fileDescriptor
        let reply = await Task.detached {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            return count > 0 ? Data(bytes.prefix(count)) : Data()
        }.value
        let object = try JSONSerialization.jsonObject(with: reply)
        let fields = try #require(object as? [String: Any])
        #expect(fields["of"] as? String == "request_permission")
        #expect(fields["permission"] as? String == permission.rawValue)
        #expect(fields["granted"] as? Bool == false)
    }
}
