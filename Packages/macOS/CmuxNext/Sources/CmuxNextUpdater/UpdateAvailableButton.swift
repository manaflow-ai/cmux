/// The titlebar's quiet Update Available button (``UpdaterService/availableButton``): a found
/// update that waits for a click; the click downloads and installs it.
nonisolated public struct UpdateAvailableButton: Equatable, Sendable {
    /// The found update's version, when Sparkle named it.
    public var version: String?

    public init(version: String?) {
        self.version = version
    }

    /// The button's tooltip and VoiceOver label.
    public var label: String {
        version.map(UpdaterStrings.updateAvailableNamed) ?? UpdaterStrings.updateAvailableButton
    }
}
