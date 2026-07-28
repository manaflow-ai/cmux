extension TerminalPanel {
    /// The observable result of attaching explicit files to the terminal text box.
    enum TextBoxAttachmentRequestResult: Equatable {
        /// The mounted text box accepted the files synchronously.
        case completed
        /// The files were retained until the text box mounts.
        case queued
        /// Accepting the files would exceed the bounded pending queue.
        case queueFull
        /// The request contained no valid file URLs.
        case invalidFiles
        /// The mounted text box rejected the files.
        case insertionFailed
    }
}
