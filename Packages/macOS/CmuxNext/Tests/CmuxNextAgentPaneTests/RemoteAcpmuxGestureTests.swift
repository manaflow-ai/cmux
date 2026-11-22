import Foundation
import Synchronization
import Testing
@testable import CmuxNextAgentPane

/// A chat on another machine keeps the host's gate: the page's frames reach the remote wire only
/// after ``AgentPaneTransport``'s checks, so a prompt or a permission allow without the user's own
/// gesture in this app never leaves it, and a deny needs none (as on the local socket).
@MainActor
@Suite(.serialized) struct RemoteAcpmuxGestureTests {
    /// Records the frames the transport hands it and answers nothing but `initialize`.
    nonisolated final class RecordingWire: AcpmuxPaneWire {
        let sent = Mutex<[String]>([])
        let onFrame = Mutex<(@Sendable (String) -> Void)?>(nil)

        func open(onFrame: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            self.onFrame.withLock { $0 = onFrame }
        }
        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            sent.withLock { $0.append(text) }
            completion(true)
        }
        func cancel(code: Int, reason: String) {}
        func push(_ text: String) { onFrame.withLock { $0 }?(text) }
        func methods() -> [String] {
            sent.withLock { $0 }.compactMap { text in
                ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["method"] as? String
            }
        }
    }

    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#
    nonisolated static let pending = #"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","request":{"options":[{"optionId":"no","name":"Deny","kind":"reject_once"},{"optionId":"yes","name":"Allow","kind":"allow_once"}]}}}"#

    private func frame(_ id: Int, _ method: String, _ params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func promptsAndAllowsNeedTheUsersGestureOnTheRemoteWire() async throws {
        let wire = RecordingWire()
        let route = AgentPaneRemoteRoute(machine: "brain") { wire }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(.remote(route))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        transport.sessions.add("s")
        wire.push(Self.pending)
        #expect(await eventually { events.flatMap(\.frames).contains { $0.contains("permission_pending") } })

        let prompt = frame(5, "session/prompt", #"{"sessionId":"s","prompt":[{"type":"text","text":"hi"}]}"#)
        #expect(await transport.send(connection: id, frames: [prompt]) == .gestureRequired)
        let allow = frame(6, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"yes"}"#)
        #expect(await transport.send(connection: id, frames: [allow]) == .gestureRequired)
        #expect(!wire.methods().contains("session/prompt"))
        #expect(!wire.methods().contains("_acpmux/permission_respond"))

        let deny = frame(7, "_acpmux/permission_respond", #"{"sessionId":"s","permissionId":"p1","optionId":"no"}"#)
        #expect(await transport.send(connection: id, frames: [deny]) == nil)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [prompt]) == nil)
        #expect(await eventually { wire.methods().filter { $0 == "session/prompt" }.count == 1 })
        #expect(wire.sent.withLock { $0 }.contains { $0.contains(#""optionId":"no""#) })
        #expect(!wire.sent.withLock { $0 }.contains { $0.contains(#""optionId":"yes""#) })
    }
}
