/// Where a Chief conversation runs and the other host its card offers
/// (``HomeService/chiefHost(of:)``): "Runs in the cloud" with "Switch to
/// cmux20", or nils for a Chief with one host.
struct HomeChiefHostLine: Equatable, Sendable {
    /// The line under the Chief's name; nil keeps the engine's own line.
    var place: String?
    /// The other host's label; nil hides the switch.
    var switchTo: String?
}
