import CmuxNextDevices
import Foundation

/// Who started a Screen Sharing tab's view without a person's click: an agent's or the CLI's
/// `macScreen.open` on one of the person's own devices (Leo, 2026-11-17: "why should it get held
/// only be aperson's click? i dont like that"). The tab's toolbar shows it beside the device's
/// name, and `mac_screen.state` lists it as `started_by`.
public nonisolated struct MacScreenStarter: Sendable, Equatable {
    /// The agent session's title or the calling app, as the person knows it; nil when the call named neither.
    public let name: String?

    public init(name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// "Started by Fix the login bug", else "Started by an agent".
    var label: String {
        guard let name else { return L.t("macScreen.toolbar.startedByAgent", "Started by an agent") }
        return String(format: L.t("macScreen.toolbar.startedBy", "Started by %@"), name)
    }

    /// `mac_screen.state`'s `started_by`: the name, else `agent`.
    var stateValue: String { name ?? "agent" }
}

extension MacScreenPages {
    /// Whether device `id` is the person's own: one of `devices`, the devices Screen Sharing lists
    /// to view (`viewableDevices`). The device hub is one per account (docs/device-hub/PROTOCOL.md:
    /// "every device here is the same account's"), so every device it lists is the person's own
    /// today. When the hub names an owner (a team's or a shared device), this is the one place that
    /// changes, and such a device keeps its approval step.
    func isOwnDevice(_ id: String, among devices: [HubDevice]) -> Bool {
        devices.contains { $0.id == id }
    }

    /// Whether automation (an agent, the CLI, a script) may start viewing device `id` without a
    /// person's click: the person's own device, while Only Your Click Starts Viewing a Screen
    /// (`macScreen.onlyPersonStartsViewing`) is off. The device's host still decides whether to allow it.
    func agentMayStartViewing(_ id: String, among devices: [HubDevice]) -> Bool {
        !onlyPersonStartsViewing && isOwnDevice(id, among: devices)
    }
}
