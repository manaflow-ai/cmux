import CmuxNextHome

/// What Home's first-run panel shows for keys at one moment: the two rows'
/// shortcuts and the Switching card (nil: hidden), compared so a registry
/// change that moves none of them redraws nothing.
struct HomeFirstRunKeys: Sendable, Equatable {
    var terminal: String?
    var agent: String?
    var switching: HomeSwitchKeys?
}
