struct MainWindowZoomIntentState: Sendable, Equatable {
    private(set) var isZoomed = false

    var wantsZoomedFrame: Bool {
        isZoomed
    }

    mutating func recordZoom(isZoomed: Bool) {
        self.isZoomed = isZoomed
    }

    mutating func recordUserPlacement() {
        isZoomed = false
    }
}
