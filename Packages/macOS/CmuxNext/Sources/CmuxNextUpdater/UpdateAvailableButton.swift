/// The sidebar footer's quiet Update Available button (``UpdaterService/availableButton``): a found
/// update that waits for a click; the click downloads it, and with `updates.oneClickInstall` also
/// installs it and restarts cmux.
nonisolated public struct UpdateAvailableButton: Equatable, Sendable {
    /// The found update's version, when Sparkle named it.
    public var version: String?
    /// `updates.oneClickInstall`: the click also installs and restarts, and the label says so.
    public var restarts: Bool

    public init(version: String?, restarts: Bool = false) {
        self.version = version
        self.restarts = restarts
    }

    /// The button's tooltip and VoiceOver label.
    public var label: String {
        if restarts { return version.map(UpdaterStrings.updateAvailableRestartsNamed) ?? UpdaterStrings.updateAvailableRestarts }
        return version.map(UpdaterStrings.updateAvailableNamed) ?? UpdaterStrings.updateAvailableButton
    }
}
