import CmuxConnectivityTelemetry
import CmuxMobileTransport
import Foundation

/// What the phone's link to a Mac reports to connectivity telemetry
/// (``ConnectivityTelemetry``): one event per phase change, dial, probe, drop, roam and media
/// change. Fixed words and numbers go to everyone; the Mac id, error text and reasons are
/// ``ConnectivityEvent/Value/text`` and reach only the cmux team's records.
struct LinkConnectivityEvents: Sendable {
    let telemetry: ConnectivityTelemetry

    func phaseChanged(_ phase: LinkMachine.Phase, macID: String?) {
        var fields: [String: ConnectivityEvent.Value] = ["phase": .code(Self.name(phase))]
        if let macID { fields["mac_id"] = .text(macID) }
        var outcome = ConnectivityEvent.Outcome.info
        switch phase {
        case .idle, .macOffline:
            break
        case .signedOut:
            // The service refused even a fresh token: the session was revoked.
            outcome = .failure
        case .connecting(let transport, let attempt):
            fields["transport"] = .code(transport.rawValue)
            fields["attempt"] = .number(Double(attempt))
        case .connected(let transport, let path, let rtt):
            outcome = .success
            fields["transport"] = .code(transport.rawValue)
            fields["path"] = .code(path.rawValue)
            if let rtt { fields["rtt_ms"] = .number(Double(rtt)) }
        case .waiting(let transport, let attempt, let reason, let retryIn):
            outcome = .failure
            fields["transport"] = .code(transport.rawValue)
            fields["attempt"] = .number(Double(attempt))
            fields["retry_in_ms"] = .number(Double(retryIn.components.seconds * 1000 + retryIn.components.attoseconds / 1_000_000_000_000_000))
            fields["reason"] = .text(reason)
        }
        telemetry.record(.link, "phase", outcome: outcome, fields: fields)
    }

    func dialStarted(transport: TransportKind, endpoint: LinkEndpoint) {
        telemetry.record(.link, "dial_start", fields: [
            "transport": .code(transport.rawValue),
            "relay_only": .flag(endpoint.relayOnly),
            "block_udp": .flag(endpoint.blockUDP),
            "mac_id": .text(endpoint.macDeviceID),
            "team_id": .text(endpoint.teamID),
        ], detail: endpoint.baseURL.absoluteString)
    }

    func dialSkipped(macID: String) {
        telemetry.record(.link, "dial_skipped", outcome: .failure, fields: [
            "cause": .code("not_registered"), "mac_id": .text(macID),
        ])
    }

    func connected(_ timings: [(String, Double)]) {
        var fields: [String: ConnectivityEvent.Value] = [:]
        for (step, ms) in timings { fields["ms_\(Self.word(step))"] = .number(ms.rounded()) }
        telemetry.record(.link, "dial_ok", outcome: .success, fields: fields)
    }

    func dialFailed(_ error: any Error, transport: TransportKind) {
        var fields: [String: ConnectivityEvent.Value] = ["transport": .code(transport.rawValue)]
        if let error = error as? LinkError {
            fields["error_code"] = .safeCode(error.code)
            if !error.message.isEmpty { fields["error_message"] = .text(error.message) }
        } else {
            fields["error_code"] = .code(error is LiveAPI.Failure ? "service_refused" : "other")
            fields["error_type"] = .code(Self.word(String(describing: type(of: error))))
        }
        telemetry.record(.link, "dial_failed", outcome: .failure, fields: fields, detail: String(describing: error))
    }

    func probed(_ result: Result<UInt32?, any Error>) {
        switch result {
        case .success(let rtt):
            var fields: [String: ConnectivityEvent.Value] = ["answered_by": .code(rtt == nil ? "traffic" : "pong")]
            if let rtt { fields["rtt_ms"] = .number(Double(rtt)) }
            telemetry.record(.link, "probe_ok", outcome: .success, fields: fields)
        case .failure(let error):
            let code = (error as? LinkError).map { ConnectivityEvent.Value.safeCode($0.code) } ?? .code("other")
            telemetry.record(.link, "probe_failed", outcome: .failure, fields: ["error_code": code],
                             detail: String(describing: error))
        }
    }

    func dropped(reason: String) {
        telemetry.record(.link, "dropped", outcome: .failure, fields: ["reason": .text(reason)])
    }

    func roamed(_ steps: [(String, Double)]) {
        var fields: [String: ConnectivityEvent.Value] = ["steps": .number(Double(steps.count))]
        for (step, ms) in steps { fields["ms_\(Self.word(step))"] = .number(ms.rounded()) }
        telemetry.record(.network, "roamed", outcome: steps.isEmpty ? .failure : .success, fields: fields)
    }

    func media(_ state: VideoMediaState) {
        switch state {
        case .off: telemetry.record(.link, "media", fields: ["state": .code("off")])
        case .connecting: telemetry.record(.link, "media", fields: ["state": .code("connecting")])
        case .up(let path, let rtt):
            var fields: [String: ConnectivityEvent.Value] = ["state": .code("up"), "path": .code(path.rawValue)]
            if let rtt { fields["rtt_ms"] = .number(Double(rtt)) }
            telemetry.record(.link, "media", outcome: .success, fields: fields)
        case .failed(let reason):
            telemetry.record(.link, "media", outcome: .failure, fields: ["state": .code("failed"), "reason": .text(reason)])
        }
    }

    static func name(_ phase: LinkMachine.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .macOffline: "mac_offline"
        case .connecting: "connecting"
        case .connected: "connected"
        case .waiting: "waiting"
        case .signedOut: "signed_out"
        }
    }

    /// A step or type name as one snake_case word (a timing step from the link, a Swift type).
    static func word(_ raw: String) -> String {
        let mapped = raw.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        let word = String(mapped.prefix(36))
        return word.isEmpty ? "unknown" : word
    }
}
