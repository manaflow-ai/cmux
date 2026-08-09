import Foundation

/// Typed parameters for `mobile.browser.frame.ack`.
struct MobileBrowserFrameAckParameters: Encodable, Sendable {
    /// The Mac browser panel identifier.
    let panelID: String
    /// The cumulative displayed sequence.
    let sequence: UInt64

    /// Creates acknowledgement parameters.
    init(panelID: String, sequence: UInt64) {
        self.panelID = panelID
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey { case panelID = "panel_id"; case sequence = "seq" }
}
