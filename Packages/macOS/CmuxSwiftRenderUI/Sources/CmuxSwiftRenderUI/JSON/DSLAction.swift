import CmuxSwiftRender
import Foundation

/// A declarative action attached to an interactive JSON-DSL node.
struct DSLAction: Codable, Equatable, Sendable {
    var type: String
    var message: String?

    /// Maps this declarative action onto a ``ButtonAction`` so JSON sidebars
    /// dispatch through the same host command sink as interpreted Swift
    /// sidebars, rather than dropping the action.
    ///
    /// - `"log"` becomes ``ActionCommand/log(_:)`` with `message`.
    /// - `"openURL"` / `"open"` becomes ``ActionCommand/openURL(_:)`` with `message`.
    /// - any other `type` is treated as a cmux dispatcher method
    ///   (``ActionCommand/cmux(method:params:)`` with no params).
    var buttonAction: ButtonAction {
        switch type {
        case "log":
            return ButtonAction(commands: [.log(message ?? "")])
        case "openURL", "open":
            return ButtonAction(commands: [.openURL(message ?? "")])
        default:
            return ButtonAction(commands: [.cmux(method: type, params: [:])])
        }
    }
}
