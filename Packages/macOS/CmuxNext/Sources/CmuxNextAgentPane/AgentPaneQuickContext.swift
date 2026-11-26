import Foundation

/// What the user is looking at in cmux, for the floating chat's Include focused tab (cx-b9qi): the
/// focused tab's selection, else what it shows. The page attaches it to the next prompt only, as a
/// text chip named `name` (`quick.context`).
public struct AgentPaneQuickContext: Equatable, Sendable {
    /// The chip's label: the tab's title, marked when the text is its selection.
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    var reply: [String: Any] { ["name": name, "text": text] }
}
