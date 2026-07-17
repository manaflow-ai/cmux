/// A typed Pane Rack terminal mutation request for injected transports.
struct PaneRackRequest: Equatable, Sendable {
    var method: String
    var workspaceID: String
    var surfaceID: String?
    var paneID: String?
    var clientID: String
    var windowID: String?

    init(
        method: String,
        workspaceID: String,
        surfaceID: String? = nil,
        paneID: String? = nil,
        clientID: String,
        windowID: String? = nil
    ) {
        self.method = method
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.clientID = clientID
        self.windowID = windowID
    }
}
