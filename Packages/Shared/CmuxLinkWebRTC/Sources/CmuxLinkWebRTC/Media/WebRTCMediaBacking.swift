import CmuxLink

/// A media track backing the connection ends with its transport.
protocol WebRTCMediaBacking: MediaTrackBacking {
    func end()
}
