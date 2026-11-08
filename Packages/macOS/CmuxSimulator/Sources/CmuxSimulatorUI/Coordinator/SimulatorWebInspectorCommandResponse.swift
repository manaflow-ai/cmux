import CmuxSimulator
import Foundation

/// One bounded raw response matched to a Web Inspector JSON request id.
public struct SimulatorWebInspectorCommandResponse: Equatable, Sendable {
    /// The UTF-8 response body returned by WebKit.
    public let text: String
    /// Whether the response exceeded the pane's bounded retention limit.
    public let isTruncated: Bool

    /// Creates a bounded Web Inspector response.
    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}
