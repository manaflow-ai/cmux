struct ChromiumScreencastTransition {
    let isViewportVisible: Bool
    let isScreencastActive: Bool

    var method: String? {
        guard isViewportVisible != isScreencastActive else { return nil }
        return isViewportVisible ? "Page.startScreencast" : "Page.stopScreencast"
    }
}
