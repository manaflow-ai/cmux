import Foundation

/// An explicit, strictly parsed recovery request for one local thread.
public struct CodexWriterRecoveryRequest: Sendable {
    public let sessionID: String
    public let codexHome: String?
    public let confirmsTermination: Bool

    public init?(arguments: [String]) {
        guard arguments.count >= 2, arguments[0] == "recover",
              let identifier = UUID(uuidString: arguments[1]) else { return nil }
        var home: String?
        var confirms = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--yes", "-y":
                guard !confirms else { return nil }
                confirms = true
            case "--codex-home":
                index += 1
                guard home == nil, index < arguments.count,
                      arguments[index].hasPrefix("/"), !arguments[index].utf8.contains(0) else { return nil }
                home = arguments[index]
            default:
                return nil
            }
            index += 1
        }
        sessionID = identifier.uuidString.lowercased()
        codexHome = home
        confirmsTermination = confirms
    }
}
