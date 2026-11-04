import AppKit

extension MessagesLabHomeView {
    /// cmux: the transcript rests at its newest message, as opening a conversation in Messages does
    /// (https://github.com/manaflow-ai/cmux/issues/34562). It pins to the bottom, so the layout
    /// passes, width measures and pages that follow the open keep the newest message on the field
    /// until the person scrolls. Before the first page is installed the transcript is pinned
    /// already (a new window view starts pinned); nothing to do then.
    public func showNewest() {
        controller.demo?.pinToBottom()
    }
}
