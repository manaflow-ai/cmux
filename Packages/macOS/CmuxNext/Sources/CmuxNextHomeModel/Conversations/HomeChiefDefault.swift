import CmuxChiefList

/// Which Chief Home opens by default (#64, 2026-10-21): this Mac's Chief while this Mac's
/// optchat-chief runs, else the Hosted (cloud) Chief. Settings > Chief's Engine row
/// (`home.chiefEngine`, Leo's list 89(3)) can force either one. The rule is the shared
/// ``ChiefDefault`` (CmuxChiefList), the one the iPhone's Home uses.
public nonisolated enum HomeChiefDefault: String, Sendable, CaseIterable {
    /// This Mac's Chief while its optchat-chief runs, else the Hosted Chief. A moment between two
    /// hosts (an update's handoff, a restart) still counts as running; only a shutdown, a Mac that
    /// cannot start a host, or one that kept dying gives the Hosted Chief (`ChiefHome.isOn`).
    case auto
    /// Always this Mac's Chief.
    case local
    /// Always the cloud Chief (the Hosted Chief, or the server's when the user switched to it).
    case hosted

    /// The choice `home.chiefEngine` names; Auto for none or an unknown value.
    public init(setting: String?) {
        self = setting.flatMap(Self.init(rawValue:)) ?? .auto
    }

    /// This Mac's Chief is the default: forced, or Auto while this Mac's optchat-chief runs.
    public func prefersLocal(localRunning: Bool) -> Bool {
        ChiefDefault(setting: rawValue).prefersLocal(localRunning: localRunning)
    }
}
