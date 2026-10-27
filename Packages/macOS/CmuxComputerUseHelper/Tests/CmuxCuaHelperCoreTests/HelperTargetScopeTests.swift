// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

@Suite struct HelperTargetScopeTests {
    @Test(arguments: ["", "com.apple.Terminal"])
    func requestScopeCannotUnlockTerminal(requestScope: String) throws {
        try checkRequest(launchScope: "", bundleID: "com.apple.Terminal", requestScope: requestScope, allowed: false)
    }

    @Test func requestScopeCannotReplaceTheLaunchScope() throws {
        let own = "com.cmuxterm.app.debug.guard-test"
        try checkRequest(launchScope: own, bundleID: own, requestScope: "com.apple.Terminal", allowed: true)
    }

    private func checkRequest(launchScope: String, bundleID: String, requestScope: String, allowed: Bool) throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let client = descriptors[0]
        let serverDescriptor = descriptors[1]
        defer { close(client) }
        // Bound a failed read. No sleep is used to coordinate the server.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        try #require(setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let daemon = ProcessStamp(pid: 10, startSeconds: 1, startMicroseconds: 0)
        let secret = Data([1, 2, 3])
        let admission = AdmissionState()
        admission.configure(AdmissionConfig(helperUID: geteuid(), acpmuxCDHashes: [Data([1])],
                                            acpmuxRequirement: nil, acpmuxDaemons: [daemon], secret: secret))
        let server = HelperSocketServer(path: "unused", admission: admission,
                                        inspector: Inspector(daemon: daemon), tools: LaunchScopedTools(scope: launchScope))
        let worker = Thread { server.serve(serverDescriptor) }
        worker.start()
        let hello = HelperWire.line(["secret": HelperWire.hex(secret)])
        let request = HelperWire.line([
            "id": 1, "method": "tools/call", "name": "click",
            "allowed_target_bundle_ids": requestScope,
            "arguments": ["bundle_id": bundleID,
                          "allowed_target_bundle_ids": "com.apple.Terminal",
                          "_cua_allowed_target_bundle_ids": ["com.apple.Terminal"]] as [String: Any],
        ])
        let bytes = hello + request
        try #require(bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } == bytes.count)
        var buffer = HelperWire.LineBuffer()
        var replies: [Data] = []
        while replies.count < 2 {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &chunk, chunk.count)
            try #require(count > 0, "The helper must answer the request")
            let lines = buffer.append(Data(chunk.prefix(count)))
            replies += try #require(lines)
        }
        let reply = try #require(HelperWire.object(replies[1]))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["allowed"] as? Bool == allowed)
    }

    private struct Inspector: PeerInspecting {
        let daemon: ProcessStamp
        func facts(forConnection descriptor: Int32, requirement: String?) -> PeerFacts? {
            PeerFacts(uid: geteuid(), stamp: ProcessStamp(pid: 11, startSeconds: 1, startMicroseconds: 0),
                      signatureValid: true, cdhash: Data([1]), satisfiesRequirement: false, ancestors: [daemon])
        }
    }

    private struct LaunchScopedTools: ToolInvoking {
        let scope: String
        func listTools() async throws -> Data { Data("[]".utf8) }
        func invoke(name: String, arguments: Data) async throws -> Data {
            result(scope: scope, arguments: arguments)
        }

        // Trap the old protocol path. A request must never replace launch policy.
        func invoke(name: String, arguments: Data, allowedTargetBundleIDs: String) async throws -> Data {
            result(scope: allowedTargetBundleIDs, arguments: arguments)
        }

        private func result(scope: String, arguments: Data) -> Data {
            let bundleID = HelperWire.object(arguments)?["bundle_id"] as? String ?? ""
            return HelperWire.json(["allowed": CuaTargetPolicy(allowedBundleIDs: scope).allows(bundleID: bundleID)])
        }
    }
}
