import Foundation

/// An agent's Move to Cloud ask's text (``CloudMoveAsks``). Keys live in Resources/Cloud.xcstrings.
enum CloudMoveAskStrings {
    static func ask(_ folder: String) -> String {
        String(format: String(localized: "cloud.moveAsk.ask", defaultValue: "The agent asks to move this chat to Cloud, copying %@ to a Cloud machine.",
                              table: "Cloud", bundle: .module), folder)
    }
    static var move: String { String(localized: "cloud.moveAsk.move", defaultValue: "Move", table: "Cloud", bundle: .module) }
    static var notNow: String { String(localized: "cloud.moveAsk.notNow", defaultValue: "Not now", table: "Cloud", bundle: .module) }
    static var always: String { String(localized: "cloud.moveAsk.always", defaultValue: "Always", table: "Cloud", bundle: .module) }
    static func alwaysHint(_ folder: String) -> String {
        String(format: String(localized: "cloud.moveAsk.alwaysHint", defaultValue: "Move without asking whenever an agent in %@ asks", table: "Cloud", bundle: .module),
               folder)
    }
    static func movingAlways(_ folder: String) -> String {
        String(format: String(localized: "cloud.moveAsk.movingAlways", defaultValue: "Moving this chat to Cloud. Agents in %@ move without asking.",
                              table: "Cloud", bundle: .module), folder)
    }
    static var askFirst: String { String(localized: "cloud.moveAsk.askFirst", defaultValue: "Ask first next time", table: "Cloud", bundle: .module) }
    static var dismiss: String { String(localized: "cloud.moveAsk.dismiss", defaultValue: "Dismiss", table: "Cloud", bundle: .module) }
    static var notInChat: String {
        String(localized: "cloud.moveAsk.notInChat", defaultValue: "Only an agent in a chat on this Mac can ask to move it to Cloud.", table: "Cloud", bundle: .module)
    }
    static var onlyOwnChat: String {
        String(localized: "cloud.moveAsk.onlyOwnChat", defaultValue: "An agent can ask to move only its own chat.", table: "Cloud", bundle: .module)
    }
    static var noPage: String {
        String(localized: "cloud.moveAsk.noPage", defaultValue: "Couldn't show the question in the chat, so nothing moved. Ask the person to run Move to Cloud on this chat.", table: "Cloud", bundle: .module)
    }
    static var noMove: String {
        String(localized: "cloud.moveAsk.noMove", defaultValue: "Move to Cloud isn't available for this chat right now.", table: "Cloud", bundle: .module)
    }
    static var bringBackIsPersons: String {
        String(localized: "cloud.moveAsk.bringBackIsPersons", defaultValue: "Only a person can bring a chat back from Cloud.", table: "Cloud", bundle: .module)
    }
}
