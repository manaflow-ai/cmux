// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxCuaHelperCore
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
        let reply = try #require(output.fileHandleForReading.read(upToCount: 4096))
        let fields = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(fields["of"] as? String == "request_permission")
        #expect(fields["permission"] as? String == permission.rawValue)
        #expect(fields["granted"] as? Bool == false)
    }
}
