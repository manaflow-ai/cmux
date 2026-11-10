import Foundation

/// The Chief profile panel's Settings tab and its Computer tab's control bar (who drives the
/// Chief's computer, ``HomeChiefComputerControlBar``).
extension HomeEngineStrings {
    static var tabSettings: String {
        String(localized: "home.engine.tab.settings", defaultValue: "Settings", table: "Home", bundle: .module)
    }
    static var editChief: String {
        String(localized: "home.engine.editChief", defaultValue: "Edit Chief…", table: "Home", bundle: .module)
    }
    static var computerExpand: String {
        String(localized: "home.engine.computer.expand", defaultValue: "Expand", table: "Home", bundle: .module)
    }
    static func computerChiefDriving(_ chief: String) -> String {
        String(localized: "home.engine.computer.chiefDriving", defaultValue: "\(chief) is using the computer", table: "Home", bundle: .module)
    }
    static var computerYouDrive: String {
        String(localized: "home.engine.computer.youDrive", defaultValue: "You’re in control", table: "Home", bundle: .module)
    }
    static var computerTakeOver: String {
        String(localized: "home.engine.computer.takeOver", defaultValue: "Take Over", table: "Home", bundle: .module)
    }
    static func computerGiveBack(_ chief: String) -> String {
        String(localized: "home.engine.computer.giveBack", defaultValue: "Give Back to \(chief)", table: "Home", bundle: .module)
    }
    static func computerControlFailed(_ chief: String) -> String {
        String(localized: "home.engine.computer.controlFailed", defaultValue: "Couldn’t reach \(chief)’s computer", table: "Home", bundle: .module)
    }
    static func computerNeedsCloudOrMachine(_ chief: String) -> String {
        String(localized: "home.engine.computer.needsCloudOrMachine", defaultValue: "Move \(chief) to cmux Cloud, or pick a Cloud machine for it below", table: "Home", bundle: .module)
    }
    static func computerOnMachine(_ chief: String) -> String {
        String(localized: "home.engine.computer.onMachine", defaultValue: "\(chief) works on a Cloud machine", table: "Home", bundle: .module)
    }
    static var computerLocalLimit: String {
        String(localized: "home.engine.computer.localLimit", defaultValue: "Your Chiefs on this Mac already have as many computers as they can. Try again when one ends.",
               table: "Home", bundle: .module)
    }
    /// The Computer Use picker's item for the Chief's own computer (Set Up Computer in its profile).
    static var computerOwn: String {
        String(localized: "home.engine.computer.own", defaultValue: "Own Cloud Computer", table: "Home", bundle: .module)
    }
    static var computerNotOnServer: String {
        String(localized: "home.engine.computer.notOnServer", defaultValue: "Computers aren’t available on this server yet", table: "Home", bundle: .module)
    }
}
