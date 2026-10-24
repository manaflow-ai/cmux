public import Foundation

/// Where the contents of a relaunched chat's composer chips still are: their files from the last
/// quit (``AgentPaneRelaunchWake``), by attachment id, in the folder the launch took them into. The
/// launch reads only the list of chips; a chat's chip contents are read from here off the main
/// thread when its page asks for its state (``AgentPaneWakeState/readingBack(budget:)``, at its
/// `ready` handshake), or carried into the next quit's save when its page never asked (#17587).
public nonisolated struct AgentPaneKeptChips: Sendable, Equatable {
    /// The folder holding the files: the launch's own (``AgentPaneRelaunchWake/takenAttachmentsDirectoryName``).
    public var folder: URL
    /// Each chip's file name in ``folder``, by attachment id.
    public var files: [String: String]

    /// The files `files` names in `folder`.
    public init(folder: URL, files: [String: String]) {
        self.folder = folder
        self.files = files
    }
}
