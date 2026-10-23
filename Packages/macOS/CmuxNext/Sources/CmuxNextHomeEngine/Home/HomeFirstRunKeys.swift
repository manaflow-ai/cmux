package import CmuxNextHome

/// What Home's first-run panel shows for keys at one moment: the two rows'
/// shortcuts and the Switching card (nil: hidden), compared so a registry
/// change that moves none of them redraws nothing.
package struct HomeFirstRunKeys: Sendable, Equatable {
    package var terminal: String?
    package var agent: String?
    package var switching: HomeSwitchKeys?

    package init(terminal: String? = nil, agent: String? = nil, switching: HomeSwitchKeys? = nil) {
        self.terminal = terminal
        self.agent = agent
        self.switching = switching
    }
}
