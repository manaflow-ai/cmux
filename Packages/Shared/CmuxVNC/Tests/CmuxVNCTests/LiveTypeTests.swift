import Foundation
import Testing
@testable import CmuxVNC

/// `CMUX_VNC_CLICK_TYPE="x,y"` (+ CMUX_VNC_LIVE_HOST/USER, password from
/// CMUX_VNC_PASSWORD_FILE): over Screen Sharing, clicks a point, types the
/// password file's text, then clicks `CMUX_VNC_CLICK_AFTER="x,y"`, the way a
/// person at a remote Mac would (secure fields accept Screen Sharing input).
struct LiveTypeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_VNC_CLICK_TYPE"] != nil))
    func clickTypeClick() async throws {
        let env = ProcessInfo.processInfo.environment
        func point(_ key: String) -> (Int, Int)? {
            let parts = (env[key] ?? "").split(separator: ",").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let secret = try String(contentsOfFile: env["CMUX_VNC_PASSWORD_FILE"] ?? "", encoding: .utf8).trimmingCharacters(in: .newlines)
        let parsed = try #require(VNCEndpoint.parse(env["CMUX_VNC_LIVE_HOST"] ?? ""))
        let client = VNCClient(endpoint: parsed.endpoint, options: VNCSessionOptions(credentials: VNCCredentials(username: env["CMUX_VNC_LIVE_USER"], password: secret)))
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case .connected = await events.next() else { Issue.record("no connect"); return }
        if let (x, y) = point("CMUX_VNC_CLICK_TYPE") {
            await client.pointer(x: x, y: y, buttons: .left)
            await client.pointer(x: x, y: y, buttons: [])
            try await Task.sleep(for: .milliseconds(300))
            await client.type(secret)
        }
        try await Task.sleep(for: .milliseconds(300))
        if let (x, y) = point("CMUX_VNC_CLICK_AFTER") {
            await client.pointer(x: x, y: y, buttons: .left)
            await client.pointer(x: x, y: y, buttons: [])
        }
        try await Task.sleep(for: .milliseconds(500))
        await client.disconnect()
    }
}
