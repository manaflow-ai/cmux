@_spi(Testing) import CmuxLinkWebRTC

/// Starts a datagram listener once, before the first open (underlay
/// endpoints are built synchronously).
actor ListenerStarter {
    let listener: WebRTCDatagramListener
    private var started = false

    init(listener: WebRTCDatagramListener) {
        self.listener = listener
    }

    func ensure() async {
        guard !started else { return }
        started = true
        await listener.start()
    }
}
