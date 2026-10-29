#if DEBUG
import Foundation
import CmuxNextServer
import CmuxNextSettings

/// `debug.join_consent {team?, name?, screen?, control?, ask?, settings?}` (captures): This Mac reads
/// as joined from a fixture status instead of acpmux, so Settings > Devices shows its consent switches
/// with no join, team or platform; `ask` (a requesting machine's name) shows the one-time sheet;
/// `settings` (default true) opens Settings > Devices. Writes go to a fixture line that is the person.
@MainActor
enum DebugJoinConsent {
    /// The status the app reads while set (``JoinConsentServices/app(_:)``).
    static var status: JoinStatus?
    static let line = FixtureLine()

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        status = JoinStatus(credentialPresent: true, machineId: "m_fixture", teamId: "team_fixture",
                            teamName: params["team"]?.stringValue ?? "Example Team", name: params["name"]?.stringValue ?? "studio",
                            screen: params["screen"]?.boolValue ?? false, control: params["control"]?.boolValue ?? false)
        let model = services.joinConsent
        if params["settings"]?.boolValue ?? true { try? services.settingsWindow.show(section: nil, route: "#/settings/devices") }
        // task-owner: one status read per call; the sheet shows after it
        Task { @MainActor in
            await model.refresh()
            if let requester = params["ask"]?.stringValue {
                model.debugResetAsk()
                model.refused(JoinConsentRefusal(requester: requester, surface: params["surface"]?.stringValue == "control" ? .control : .screen))
            }
        }
        return .object(["joined": .bool(true)])
    }

    /// A line acpmux proved as the person that writes into the fixture status.
    final class FixtureLine: JoinConsentLine {
        var isPerson: Bool { true }
        func set(_ surface: JoinConsentSurface, on: Bool) async -> Bool {
            if surface == .screen { DebugJoinConsent.status?.screen = on } else { DebugJoinConsent.status?.control = on }
            return true
        }
        func close() {}
    }
}

extension JoinConsentModel {
    /// Captures show the sheet again: forget that it showed.
    func debugResetAsk() {
        UserDefaults.standard.removeObject(forKey: JoinConsentServices.askShownKey)
    }
}
#endif
