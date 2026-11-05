import Foundation

/// The Chief Settings card's Computer section (``HomeChiefComputerSection``).
extension HomeEngineStrings {
    /// The caption under the Chief's computer's screen.
    static func computerTitle(_ chief: String) -> String {
        String(localized: "home.engine.computer.caption", defaultValue: "\(chief)’s screen", table: "Home", bundle: .module)
    }
    /// The Chief Settings card's section header over the computer.
    static var computerSection: String {
        String(localized: "home.engine.section.computer", defaultValue: "Computer", table: "Home", bundle: .module)
    }
    static var closeCard: String {
        String(localized: "home.engine.close", defaultValue: "Close", table: "Home", bundle: .module)
    }
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
}
