/// A byte stream cannot be assembled into valid UTF-8 text.
enum UTF8ChunkAssemblerError: Error, Equatable {
    case invalidEncoding
}
