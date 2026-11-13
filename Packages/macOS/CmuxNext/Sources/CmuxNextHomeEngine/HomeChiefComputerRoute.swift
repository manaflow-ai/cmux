public import CoreGraphics
import Foundation
import ImageIO

/// The Chief's computer through the Cloud service as its signed-in owner (backend chief-brain/routes.ts):
/// `GET v1/chiefs/<agent>/computer` for its state and `GET v1/chiefs/<agent>/computer/screen` for a
/// JPEG of its screen while it runs. Read only: neither starts, wakes nor drives the computer.
///
/// A Chief of this Mac has no agent id: its computer is the same Chief computer under the owner's session and
/// the Mac's id for it (backend chief-brain/local-computer-routes.ts, `v1/local-chiefs/<id>/computer…`), keyed
/// here as `local:<id>` (``localKey(_:)``) wherever an agent id goes.
public nonisolated struct HomeChiefComputerRoute: Sendable {
    /// The Chief's computer key: its agent id (`agent_…`), or `local:<id>` for a Chief of this Mac; nil for none.
    let agent: @MainActor @Sendable () -> String?
    let send: HomeChiefHostedEngine.Send

    public init(agent: @escaping @MainActor @Sendable () -> String?, send: @escaping HomeChiefHostedEngine.Send) {
        self.agent = agent
        self.send = send
    }

    /// The key of a Chief of this Mac's own computer: `local:<id>` for its conversation `id`; nil for an id the route does not take.
    public static func localKey(_ id: String) -> String? {
        isLocalID(id) ? "local:\(id)" : nil
    }

    /// A computer key's Worker path (`v1/chiefs/<agent>` or `v1/local-chiefs/<id>`); nil for anything else, which never reaches a path.
    public static func base(of key: String) -> String? {
        if key.hasPrefix("local:") {
            let id = String(key.dropFirst("local:".count))
            return isLocalID(id) ? "v1/local-chiefs/\(id)" : nil
        }
        let agentID = key.hasPrefix("agent_") && key.count <= 64 && key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        return agentID ? "v1/chiefs/\(key)" : nil
    }

    /// What the local route takes as a Chief id (backend LOCAL_CHIEF_ID): 1 to 64 of A-Z a-z 0-9 _ -.
    static func isLocalID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// The computer's status; nil when signed out, not reached, or not the owner.
    @MainActor
    public func status() async -> HomeChiefComputer.Status? {
        guard let base = agent().flatMap(Self.base(of:)), let reply = try? await send("GET", "\(base)/computer", nil),
              reply.status == 200 else { return nil }
        return HomeChiefComputer.Status(json: reply.body)
    }

    /// The screen now, decoded off the main thread; nil while it sleeps or when not reached.
    @MainActor
    public func screen() async -> CGImage? {
        guard let base = agent().flatMap(Self.base(of:)), let reply = try? await send("GET", "\(base)/computer/screen", nil),
              reply.status == 200 else { return nil }
        return await Self.decode(reply.body)
    }

    /// Where a Cloud machine's screen is written for the Computer tab (its own file: the Chief's `screenshot` has another).
    public static let machineScreenFile = "/home/cmux/.cache/cmux-computer/panel.png"

    /// The shell that writes a Cloud machine's screen to ``machineScreenFile``: the steps of `cmux cloud computer screenshot`
    /// (cloud_tools.rs DESKTOP_PRELUDE and its `screenshot` op), run through the machine's exec.
    public static let machineScreenCommand = #"""
    export HOME=/home/cmux PATH=/opt/cmux/current/bin:$PATH DISPLAY=:99 XAUTHORITY=/home/cmux/.cache/cmux-display/Xauthority-99 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/cmux-agent-a11y-99/bus
    cmux-cua status >/dev/null 2>&1 || sudo -n systemctl start cmux-agent-cua.service >/dev/null 2>&1 || exit 1
    scope=$(cmux-cua call get_config '{}' 2>/dev/null | sed -n 's/^[[:space:]]*"capture_scope":[[:space:]]*"\([a-z]*\)".*/\1/p')
    if [ "$scope" != desktop ]; then cmux-cua call set_config '{"capture_scope":"desktop"}' >/dev/null || exit 1; fi
    mkdir -p /home/cmux/.cache/cmux-computer && rm -f /home/cmux/.cache/cmux-computer/panel.png
    cmux-cua call get_desktop_state '{"screenshot_out_file":"/home/cmux/.cache/cmux-computer/panel.png"}' >/dev/null && test -s /home/cmux/.cache/cmux-computer/panel.png || exit 1
    cmux-cua call get_cursor_position '{}' 2>/dev/null || true
    """#

    /// The pointer in the screen's pixels, from what ``machineScreenCommand`` printed; nil when it did not say.
    public static func machinePointer(_ output: String) -> CGPoint? {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = (value["x"] as? NSNumber)?.doubleValue, let y = (value["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A screen file's bytes as the Cloud API answers them, decoded off the main thread; nil for anything else.
    public static func image(base64: String) async -> CGImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return await decode(data)
    }

    @concurrent
    static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
