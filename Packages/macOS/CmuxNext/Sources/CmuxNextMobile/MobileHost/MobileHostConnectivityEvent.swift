import CmuxConnectivityTelemetry
import Foundation

/// The phone host's state as one connectivity event (``ConnectivityTelemetry``): its phase and
/// phone count for everyone; the waiting or unavailable reason, team and device ids for the
/// cmux team only.
struct MobileHostConnectivityEvent: Sendable {
    let event: ConnectivityEvent

    /// The phase as one fixed word.
    static func kind(_ phase: MobileHostState.Phase) -> String {
        switch phase {
        case .off: "off"
        case .unavailable: "unavailable"
        case .connecting: "connecting"
        case .online: "online"
        case .waiting: "waiting"
        case .removed: "removed"
        }
    }

    init(_ state: MobileHostState, date: Date = Date()) {
        var fields: [String: ConnectivityEvent.Value] = ["phones": .number(Double(state.phones.count))]
        let outcome: ConnectivityEvent.Outcome
        switch state.phase {
        case .off:
            fields["phase"] = .code("off")
            outcome = .info
        case .unavailable(let reason):
            fields["phase"] = .code("unavailable")
            fields["reason"] = .text(reason)
            outcome = .failure
        case .connecting:
            fields["phase"] = .code("connecting")
            outcome = .info
        case .online:
            fields["phase"] = .code("online")
            outcome = .success
        case .waiting(let reason):
            fields["phase"] = .code("waiting")
            fields["reason"] = .text(reason)
            outcome = .failure
        case .removed:
            fields["phase"] = .code("removed")
            outcome = .info
        }
        if let teamID = state.teamID { fields["team_id"] = .text(teamID) }
        if let deviceID = state.deviceID { fields["device_id"] = .text(deviceID) }
        event = ConnectivityEvent(.phoneHost, "phase", outcome: outcome, fields: fields, date: date)
    }
}
