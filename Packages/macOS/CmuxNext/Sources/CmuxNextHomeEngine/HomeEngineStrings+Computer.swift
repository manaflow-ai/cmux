import Foundation

/// The Chief Settings card's Computer section (``HomeChiefComputerSection``).
extension HomeEngineStrings {
    /// The caption under the Chief's computer's screen.
    static func computerTitle(_ chief: String) -> String {
        String(localized: "home.engine.computer.caption", defaultValue: "\(chief)’s screen", table: "Home", bundle: .module)
    }
    static var tabDetails: String {
        String(localized: "home.engine.tab.details", defaultValue: "Details", table: "Home", bundle: .module)
    }
    static var tabComputer: String {
        String(localized: "home.engine.tab.computer", defaultValue: "Computer", table: "Home", bundle: .module)
    }
    public static var computerPageTitle: String { tabComputer }
    static func computerPaywall(_ chief: String) -> String {
        String(localized: "home.engine.computer.paywall", defaultValue: "\(chief) gets its own computer with cmux Cloud", table: "Home", bundle: .module)
    }
    static var computerUpgrade: String {
        String(localized: "home.engine.computer.upgrade", defaultValue: "Upgrade", table: "Home", bundle: .module)
    }
    static func computerNeedsCloudChief(_ chief: String) -> String {
        String(localized: "home.engine.computer.needsCloud", defaultValue: "Move \(chief) to cmux Cloud to give it a computer", table: "Home", bundle: .module)
    }
    static var computerMove: String {
        String(localized: "home.engine.computer.move", defaultValue: "Move to Cloud", table: "Home", bundle: .module)
    }
    static var computerProvision: String {
        String(localized: "home.engine.computer.provision", defaultValue: "Set Up Computer", table: "Home", bundle: .module)
    }
    static func computerProvisionNote(_ chief: String) -> String {
        String(localized: "home.engine.computer.provision.note", defaultValue: "Give \(chief) its own computer in cmux Cloud", table: "Home", bundle: .module)
    }
    static func computerProvisioning(_ chief: String) -> String {
        String(localized: "home.engine.computer.provisioning", defaultValue: "Setting up \(chief)’s computer. This takes a few minutes.", table: "Home", bundle: .module)
    }
    static func computerProvisionFailed(_ chief: String) -> String {
        String(localized: "home.engine.computer.provision.failed", defaultValue: "\(chief)’s computer couldn’t be set up. Try again.", table: "Home", bundle: .module)
    }
    static func computerNotSetUp(_ chief: String) -> String {
        String(localized: "home.engine.computer.notSetUp", defaultValue: "Ask \(chief) to turn on its computer", table: "Home", bundle: .module)
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
