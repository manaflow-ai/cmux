import AppKit
import CmuxNextRemoteView

/// The live part of a `remote_view` tab: the pane and its stream source.
/// Development builds only (`RemoteViewAvailability`). Until the in-app
/// transport (cmux-rd-core in the client) lands, only the host `mock` has a
/// source: `MockRemoteStreamSource`, a VideoToolbox test desktop.
@MainActor
final class RemoteViewPageSession {
    /// The host name that opens the test desktop.
    static let mockHost = "mock"

    #if DEBUG
    private let pane: RemoteDesktopPane
    private let source: MockRemoteStreamSource
    private var visible = false

    private init(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) {
        // The test desktop offers upstream media, so the share buttons show.
        let source = MockRemoteStreamSource(status: Self.mockStatus)
        self.source = source
        pane = RemoteDesktopPane(hostName: record.host, source: source, inputSink: MockRemoteInputSink(host: source),
                                 initialMode: record.mode)
        pane.handlers.stop = { [weak source] in source?.end(.stoppedByViewer) }
        pane.handlers.reconnect = { [weak source] in
            source?.setStatus(Self.mockStatus)
            source?.requestKeyframe()
        }
        pane.handlers.close = closeTab
        pane.upstreamControl = source
    }

    private nonisolated static let mockStatus = RemoteViewStatus(
        path: .direct, rttMs: 4, state: .streaming, upstream: RemoteUpstreamStatus(offered: true)
    )

    var view: NSView { pane.view }
    var focusTarget: NSView { pane.view.focusView }

    /// Starts the stream while the tab is shown. Idempotent.
    func resume() {
        guard !visible else { return }
        visible = true
        pane.start()
        source.requestKeyframe()
    }

    /// Pauses the stream while the tab is hidden or closed. The last frame stays.
    func pause() {
        guard visible else { return }
        visible = false
        pane.stop()
    }

    #else
    var view: NSView { NSView() }
    var focusTarget: NSView { view }
    func resume() {}
    func pause() {}
    #endif

    /// A session for `record`, or nil when this build cannot show it.
    static func make(record: RemoteViewTabRecord, closeTab: @escaping @MainActor () -> Void) -> RemoteViewPageSession? {
        #if DEBUG
        guard RemoteViewAvailability().isAvailable, record.host.lowercased() == mockHost else { return nil }
        return RemoteViewPageSession(record: record, closeTab: closeTab)
        #else
        return nil
        #endif
    }
}
