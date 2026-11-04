import Foundation

/// The Chief Settings card's Computer section (``HomeChiefComputerSection``).
extension HomeEngineStrings {
    static var computerSection: String { String(localized: "home.engine.computer", defaultValue: "Computer", table: "Home", bundle: .module) }
    static var computerAsleep: String {
        String(localized: "home.engine.computer.asleep", defaultValue: "Computer is asleep", table: "Home", bundle: .module)
    }
    static var computerWaking: String {
        String(localized: "home.engine.computer.waking", defaultValue: "Waking up…", table: "Home", bundle: .module)
    }
    static var computerConnecting: String {
        String(localized: "home.engine.computer.connecting", defaultValue: "Connecting…", table: "Home", bundle: .module)
    }
    static var computerUnavailable: String {
        String(localized: "home.engine.computer.unavailable", defaultValue: "Computer isn’t available", table: "Home", bundle: .module)
    }
    static var computerStateLive: String {
        String(localized: "home.engine.computer.state.live", defaultValue: "Running", table: "Home", bundle: .module)
    }
    static var computerStateAsleep: String {
        String(localized: "home.engine.computer.state.asleep", defaultValue: "Asleep", table: "Home", bundle: .module)
    }
    static var computerStateWaking: String {
        String(localized: "home.engine.computer.state.waking", defaultValue: "Starting", table: "Home", bundle: .module)
    }
    static var computerStateUnavailable: String {
        String(localized: "home.engine.computer.state.unavailable", defaultValue: "Unavailable", table: "Home", bundle: .module)
    }
    /// VoiceOver's name for the live screen.
    static func computerScreen(_ name: String) -> String {
        String(localized: "home.engine.computer.screen", defaultValue: "Screen of \(name)", table: "Home", bundle: .module)
    }
}
