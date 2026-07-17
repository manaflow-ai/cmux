import Foundation

/// Injectable transport seam for Pane Rack create and close mutations.
protocol PaneRackRequestSending: Sendable {
    func sendPaneRackRequest(_ request: PaneRackRequest) async throws -> Data
}
