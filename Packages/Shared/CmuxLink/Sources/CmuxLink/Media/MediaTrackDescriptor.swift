/// Names a media track: the browser surface video, a VNC display, voice.
public struct MediaTrackDescriptor: Sendable, Hashable {
    public var id: String
    public var kind: MediaTrackKind
    /// Feature label, for example `browser/tab_9f2` or `rd/display-1`.
    public var label: String

    public init(id: String, kind: MediaTrackKind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}
