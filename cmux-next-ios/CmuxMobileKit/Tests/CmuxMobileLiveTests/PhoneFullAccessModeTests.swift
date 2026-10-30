import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A phone whose Full-access setting is on (Settings > Devices on the Mac, acpmux `initialize`
/// `_meta.acpmux.fullAccess`) also gets the harness's Full access mode in its mode menus;
/// acpmux still decides every switch by that setting. Off, missing (an older Mac) or refused,
/// the menus offer only the modes that ask, as before.
@MainActor
@Suite struct PhoneFullAccessModeTests {
    /// What the fake acpmux says: the setting as `initialize` reports it (nil: an acpmux that
    /// does not say), and whether a switch into Full access is refused for it.
    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var _fullAccess: Bool?
        private var _modeSets: [String] = []
        init(fullAccess: Bool?) { _fullAccess = fullAccess }
        var fullAccess: Bool? {
            get { lock.withLock { _fullAccess } }
            set { lock.withLock { _fullAccess = newValue } }
        }
        var modeSets: [String] { lock.withLock { _modeSets } }
        func setMode(_ mode: String) { lock.withLock { _modeSets.append(mode) } }
    }

    nonisolated static let claudeModes = #"{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"acceptEdits","name":"Accept Edits"},{"id":"plan","name":"Plan Mode"},{"id":"bypassPermissions","name":"Bypass Permissions"}]}"#

    nonisolated static func link(_ mac: Mac) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                let meta = mac.fullAccess.map { #","_meta":{"acpmux":{"fullAccess":\#($0)}}"# } ?? ""
                return [reply(#"{"protocolVersion":1\#(meta)}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"claude","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[],"modes":\#(claudeModes)},"hasMore":false,"lastSeq":0,"events":[]}"#)]
            case "session/set_mode":
                let mode = (object["params"] as? [String: Any])?["modeId"] as? String ?? ""
                mac.setMode(mode)
                // acpmux's refusal of a request the mobile host marked requireFullAccess
                // (server/remote_guard.rs), when the setting does not cover the phone.
                if mode == "bypassPermissions", mac.fullAccess != true {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Full access is off for this device: turn it on for this device in Settings > Devices on the Mac","data":{"reason":"remote.full_access_required"}}}"#.utf8)]
                }
                return [reply("{}")]
            default:
                return [reply("{}")]
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s1", name: "Fix", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")

    func openChat(_ mac: Mac) async throws -> (AcpmuxHub, MockMacLink, AgentChatStore) {
        let link = Self.link(mac)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: Self.summary))
        for _ in 0..<500 where store.modes.isEmpty { await Task.yield() }
        return (hub, link, store)
    }

    @Test func fullAccessOnOffersTheHarnessFullAccessMode() async throws {
        let mac = Mac(fullAccess: true)
        // The hub is held for the whole test: a chat source holds it weakly.
        let (hub, _, store) = try await openChat(mac)
        defer { withExtendedLifetime(hub) {} }
        #expect(store.modes.map(\.id) == ["default", "plan", "bypassPermissions"])
        // Picking it sends the normal mode change.
        store.setMode("bypassPermissions")
        for _ in 0..<500 where mac.modeSets.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(mac.modeSets == ["bypassPermissions"])
        #expect(store.clientError == nil)
    }

    @Test func fullAccessOffOrMissingKeepsOnlyTheModesThatAsk() async throws {
        for setting in [false, nil] as [Bool?] {
            let (hub, _, store) = try await openChat(Mac(fullAccess: setting))
            defer { withExtendedLifetime(hub) {} }
            #expect(store.modes.map(\.id) == ["default", "plan"], "\(String(describing: setting))")
        }
    }

    /// The link drops: no chat keeps offering Full access until a connection says so again, even
    /// when that connection never gets as far as reattaching the chat.
    @Test func aDroppedLinkHidesTheModeUntilTheSettingIsReadAgain() async throws {
        let (hub, _, store) = try await openChat(Mac(fullAccess: true))
        #expect(store.modes.map(\.id).contains("bypassPermissions"))
        await hub.bind(nil)
        for _ in 0..<500 where store.modes.count != 2 { await Task.yield() }
        #expect(store.modes.map(\.id) == ["default", "plan"])
    }

    /// The setting turned off on the Mac while the app is open: the switch is refused with a
    /// sentence that says where to turn it on, and every chat's menu hides the mode again
    /// until a reconnect reads the setting anew.
    @Test func aRefusalHidesTheModeUntilTheSettingIsReadAgain() async throws {
        let mac = Mac(fullAccess: true)
        let (hub, link, store) = try await openChat(mac)
        #expect(store.modes.map(\.id).contains("bypassPermissions"))
        mac.fullAccess = false
        store.setMode("bypassPermissions")
        for _ in 0..<500 where store.clientError == nil { await Task.yield() }
        #expect(mac.modeSets == ["bypassPermissions"])
        #expect(store.clientError == "Full access is off for this iPhone. Turn it on in Settings > Devices on the Mac.")
        for _ in 0..<500 where store.modes.count != 2 { await Task.yield() }
        #expect(store.modes.map(\.id) == ["default", "plan"])

        // Turned on again: the next connection's initialize offers it again.
        mac.fullAccess = true
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        for _ in 0..<500 where store.modes.count != 3 { await Task.yield() }
        #expect(store.modes.map(\.id) == ["default", "plan", "bypassPermissions"])
    }
}
