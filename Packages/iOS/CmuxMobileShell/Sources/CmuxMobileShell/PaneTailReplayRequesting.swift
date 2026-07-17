/// Requests an authoritative full render-grid frame for a Pane Rack surface.
@MainActor
protocol PaneTailReplayRequesting: AnyObject {
    func requestPaneTailReplay(surfaceID: String)
}
