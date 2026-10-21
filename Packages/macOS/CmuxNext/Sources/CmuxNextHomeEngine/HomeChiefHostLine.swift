/// Where a Chief conversation runs and the other host its card offers
/// (the app's `HomeService.chiefHost(of:)`, ``HomeChiefSettingsView/setHost(place:switchTo:)``):
/// "Runs in the cloud" with "Switch to cmux20", or nils for a Chief with one host.
public nonisolated struct HomeChiefHostLine: Equatable, Sendable {
    /// The line under the Chief's name; nil keeps the engine's own line.
    public var place: String?
    /// The other host's label; nil hides the switch.
    public var switchTo: String?

    public init(place: String? = nil, switchTo: String? = nil) {
        self.place = place
        self.switchTo = switchTo
    }
}
