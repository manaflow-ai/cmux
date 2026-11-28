import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The phone's connection contract (cmux-next-ios/contract/README.md): the scenarios of
/// rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json driven through
/// ``LinkMachine``, the same file Rust checks its events against (tests/connection_contract.rs).
///
/// A `link` step is a Rust `LinkEvent`. It reaches the machine as the app maps it: FFIMacLink's
/// StateObserver turns it into a ``LinkState`` and LinkController.adopt into a machine event
/// (or, for Suspect, its quick probe). Keep `deliver` in step with those two. A step or event
/// this file does not know fails the suite: a new Rust event, or an old one in a new place, is
/// not handled on iOS until this passes.
@Suite struct ConnectionContractScenarioTests {
    static func contract(filePath: String = #filePath) throws -> [String: Any] {
        // Tests/CmuxMobileLiveTests/<file> -> cmux-next-ios
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static let target = LinkMachine.Target(macID: "mac-1", name: "Mac", isOnline: true)

    @Test func everyScenarioRunsOnTheMachineAsTheContractSays() throws {
        let scenarios = try #require(Self.contract()["scenarios"] as? [[String: Any]])
        #expect(!scenarios.isEmpty)
        for scenario in scenarios {
            let label = scenario["name"] as? String ?? "?"
            var machine = LinkMachine(transport: .wireGuard)
            var transport: TransportKind = .wireGuard
            var path: LinkPathKind?
            let steps = try #require(scenario["steps"] as? [[String: Any]])
            for (index, step) in steps.enumerated() {
                let at = "\(label) step \(index) (\(step["do"] as? String ?? "?") \(step["event"] as? String ?? ""))"
                let effects = Self.apply(step, to: &machine, transport: &transport, path: &path, at: at)
                #expect(Self.phaseName(machine.phase) == step["phase"] as? String, "\(at): phase \(machine.phase)")
                #expect(effects.map(Self.effectName) == (step["effects"] as? [String] ?? []), "\(at): effects \(effects)")
                if let media = step["media_after"] as? String {
                    #expect(Self.mediaName(machine.media) == media, "\(at): media \(machine.media)")
                }
            }
        }
    }

    static func apply(_ step: [String: Any], to machine: inout LinkMachine, transport: inout TransportKind,
                      path current: inout LinkPathKind?, at: String) -> [LinkMachine.Effect] {
        let generation = machine.generation
        switch step["do"] as? String {
        case "target_online": return machine.handle(.target(target))
        case "target_offline":
            return machine.handle(.target(.init(macID: target.macID, name: target.name, isOnline: false)))
        case "dial_failed": return machine.handle(.dialFailed(generation: generation, reason: "no answer"))
        case "probe_failed": return machine.handle(.probeFailed(generation: generation, reason: "probe timed out"))
        case "retry_due": return machine.handle(.retryDue(generation: generation))
        case "open": return machine.handle(.open)
        case "background": return machine.handle(.background)
        case "parked": return machine.handle(.parked(generation: generation))
        case "foreground": return machine.handle(.foreground)
        case "network_changed": return machine.handle(.networkChanged)
        case "mac_signaled": return machine.handle(.macSignaled)
        case "resumed":
            let ms = (step["away_ms"] as? NSNumber)?.int64Value ?? 0
            return machine.handle(.resumed(after: .milliseconds(ms)))
        case "link":
            // A dead link's events carry the generation before the current one.
            let gen = step["stale"] as? Bool == true ? generation - 1 : generation
            guard let state = observe(step, transport: &transport, path: &current, at: at) else { return [] }
            return deliver(state, generation: gen, to: &machine)
        default:
            Issue.record("\(at): a step the contract has and iOS does not")
            return []
        }
    }

    /// FFIMacLink's StateObserver.onEvent: a Rust event as the LinkState iOS sees.
    static func observe(_ step: [String: Any], transport: inout TransportKind, path current: inout LinkPathKind?,
                        at: String) -> LinkState? {
        let path = pathKind(step["path"] as? String)
        switch step["event"] as? String {
        case "Connecting": return .connecting(.wireGuard)
        case "Connected":
            transport = .wireGuard
            current = path
            return .connected(.wireGuard, path, rttMillis: nil)
        case "PathChanged":
            guard current != nil else { return nil }
            current = path
            return .connected(transport, path, rttMillis: nil)
        case "Rtt":
            guard let current else { return nil }
            return .connected(transport, current, rttMillis: (step["millis"] as? NSNumber)?.uint32Value)
        case "Media":
            switch step["media"] as? String {
            case "Off": return .media(.off)
            case "Connecting": return .media(.connecting)
            case "Up": return .media(.up(path, rttMillis: (step["rtt_millis"] as? NSNumber)?.uint32Value))
            case "Failed": return .media(.failed(reason: step["reason"] as? String ?? ""))
            default:
                Issue.record("\(at): a MediaState iOS does not map")
                return nil
            }
        case "Disconnected":
            current = nil
            return .disconnected(reason: step["reason"] as? String ?? "")
        case "Suspect": return .suspect(silentMillis: (step["silent_millis"] as? NSNumber)?.uint32Value ?? 0)
        default:
            Issue.record("\(at): a LinkEvent iOS does not map")
            return nil
        }
    }

    /// LinkController.adopt's watch loop: a LinkState as the machine's event.
    static func deliver(_ state: LinkState, generation: Int, to machine: inout LinkMachine) -> [LinkMachine.Effect] {
        switch state {
        case .connected(_, let path, let rtt):
            var effects: [LinkMachine.Effect] = []
            if case .connecting = machine.phase {
                effects += machine.handle(.dialSucceeded(generation: generation, path: path))
            }
            return effects + machine.handle(.linkUpdated(generation: generation, path: path, rttMillis: rtt))
        case .media(let media): return machine.handle(.mediaUpdated(generation: generation, media))
        case .disconnected(let reason): return machine.handle(.linkDropped(generation: generation, reason: reason))
        case .suspect:
            // LinkController.suspect: a quick probe of a connected link.
            return machine.phase.isConnected ? [.quickProbe(generation: machine.generation)] : []
        case .idle, .connecting: return []
        }
    }

    static func pathKind(_ name: String?) -> LinkPathKind {
        switch name {
        case "Turn": .turn
        case "TurnTls": .turnTLS
        case "HttpsRelay": .httpsRelay
        case "NoPath": .noPath
        default: .direct
        }
    }

    static func phaseName(_ phase: LinkMachine.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .macOffline: "macOffline"
        case .connecting: "connecting"
        case .connected: "connected"
        case .waiting: "waiting"
        case .signedOut: "signedOut"
        }
    }

    static func effectName(_ effect: LinkMachine.Effect) -> String {
        switch effect {
        case .dial: "dial"
        case .close: "close"
        case .scheduleRetry: "scheduleRetry"
        case .probe: "probe"
        case .quickProbe: "quickProbe"
        case .park: "park"
        case .resumeParked: "resumeParked"
        case .keepStandby: "keepStandby"
        case .promoteStandby: "promoteStandby"
        case .closeStandby: "closeStandby"
        }
    }

    static func mediaName(_ media: VideoMediaState) -> String {
        switch media {
        case .off: "off"
        case .connecting: "connecting"
        case .up: "up"
        case .failed: "failed"
        }
    }
}
