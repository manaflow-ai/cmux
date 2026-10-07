/// Aggregate "is any browser pane in this workspace using a media device"
/// summary, folded across every ``BrowserPanel`` in a ``Workspace``. Drives the
/// Chrome-style media-activity glyphs on the sidebar workspace row.
struct BrowserMediaActivity: Equatable {
    /// Any browser pane has actively-playing media.
    var isPlayingAudio: Bool = false
    /// Any browser pane is capturing the microphone.
    var isUsingMicrophone: Bool = false
    /// Any browser pane is capturing the camera.
    var isUsingCamera: Bool = false

    /// Whether any tracked media device is active (used to gate row layout).
    var isActive: Bool { isPlayingAudio || isUsingMicrophone || isUsingCamera }

    /// Reduces per-pane media activity into the workspace-level summary: a
    /// device counts as active when *any* pane reports it active. Pure so the
    /// "any browser pane in the workspace is playing audio" rule is unit-testable
    /// without standing up a full ``Workspace``/``BrowserPanel`` graph.
    static func aggregating<S: Sequence>(_ perPane: S) -> BrowserMediaActivity
    where S.Element == BrowserMediaActivity {
        perPane.reduce(into: BrowserMediaActivity()) { result, pane in
            result.isPlayingAudio = result.isPlayingAudio || pane.isPlayingAudio
            result.isUsingMicrophone = result.isUsingMicrophone || pane.isUsingMicrophone
            result.isUsingCamera = result.isUsingCamera || pane.isUsingCamera
        }
    }
}
