import AppKit

extension HomeNativeTranscriptView {
    /// The open thread's root message id (MessagesLab's `ui.openThread`), nil when no thread is
    /// open: the message part of the docked Home's selection hand-off (Messages -> Channels opens
    /// `#/conversation/<id>/message/<root>`).
    public var openThreadRoot: String? { transcript.debugOpenThread }
}
