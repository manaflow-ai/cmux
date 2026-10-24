/// The outcome of saving a file page's text: the file's hash after the save and whether bytes were written.
nonisolated package struct FileSaveResult: Sendable, Equatable {
    package let hash: String
    /// False when the bytes already equal the file's: nothing was written.
    package let written: Bool

    package init(hash: String, written: Bool) {
        self.hash = hash
        self.written = written
    }
}
