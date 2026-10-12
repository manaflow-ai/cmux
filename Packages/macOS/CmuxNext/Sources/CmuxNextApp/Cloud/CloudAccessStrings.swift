import Foundation

/// A Cloud chat's file ask card's text (``CloudAccessAsks``). Keys live in Resources/Cloud.xcstrings.
enum CloudAccessStrings {
    static func ask(_ machine: String, _ path: String) -> String {
        String(format: String(localized: "cloud.access.ask", defaultValue: "An agent on %1$@ asks for %2$@ from this Mac.", table: "Cloud", bundle: .module),
               machine, path)
    }
    static func unshareable(_ machine: String, _ path: String) -> String {
        String(format: String(localized: "cloud.access.unshareable", defaultValue: "An agent on %1$@ asks for %2$@, which can't be shared from this Mac.",
                              table: "Cloud", bundle: .module), machine, path)
    }
    static func leadsTo(_ target: String) -> String {
        String(format: String(localized: "cloud.access.leadsTo", defaultValue: "It leads to %@.", table: "Cloud", bundle: .module), target)
    }
    static func reason(_ reason: String) -> String {
        String(format: String(localized: "cloud.access.reason", defaultValue: "The agent says: %@", table: "Cloud", bundle: .module), reason)
    }
    static var allowOnce: String { String(localized: "cloud.access.allowOnce", defaultValue: "Allow once", table: "Cloud", bundle: .module) }
    static func always(_ folder: String) -> String {
        String(format: String(localized: "cloud.access.always", defaultValue: "Always for %@", table: "Cloud", bundle: .module), folder)
    }
    static func alwaysHint(_ folder: String) -> String {
        String(format: String(localized: "cloud.access.alwaysHint", defaultValue: "Share %@ with this chat, read-only, until it comes back", table: "Cloud",
                              bundle: .module), folder)
    }
    static var deny: String { String(localized: "cloud.access.deny", defaultValue: "Deny", table: "Cloud", bundle: .module) }
}
