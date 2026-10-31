#if DEBUG
import Foundation
import CmuxNextServer
import CmuxNextSettings

/// `debug.join_consent {joined?, team?, name?, ask?, surface?, settings?}` (captures): This Mac reads as
/// joined (`joined` false: not joined, the page as it was before) from a fixture status instead of acpmux, so Settings > Devices shows its consent switches with no
/// join, team or platform; `ask` (a requesting machine's name) shows the one-time sheet; `settings`
/// (default true) opens Settings > Devices. Both consents start off and the RPC never sets one: only
/// the page's switch (the person's gesture) or the sheet's Allow writes, to a fixture person line.
@MainActor
enum DebugJoinConsent {
    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        // Only behind the Labs switch, as the feature itself: with it off, Mac Screen stays as it was.
        guard services.joinConsent.enabled else { return .object(["error": .string("labs.machineJoin is off")]) }
        let fixtures = services.debugFixtures
        if params["joined"]?.boolValue == false {
            fixtures.joinStatus = JoinStatus(credentialPresent: false)
        } else if fixtures.joinStatus?.credentialPresent != true {
            fixtures.joinStatus = JoinStatus(credentialPresent: true, machineId: "m_fixture", teamId: "team_fixture",
                                              teamName: params["team"]?.stringValue ?? "Example Team",
                                              name: params["name"]?.stringValue ?? "studio")
        }
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

    /// A line acpmux proved as the person, over a fixture record.
    final class FixtureLine: JoinConsentLine {
        var record = JoinConsentRecord()
        var isPerson: Bool { true }
        var supportsConsent: Bool { true }
        func read() async -> JoinConsentRecord? { record }
        func set(_ surface: JoinConsentSurface, granted: Bool, ticket: JoinConsentGrantTicket?) async -> JoinConsentRecord? {
            guard ticket?.write({}) ?? true else { return nil }
            if surface == .screen { record.screen = granted } else { record.control = granted }
            return record
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
