/// Safe internal failure category; raw filesystem details stay in private logs.
enum WorkstreamPersistenceFailure: Equatable {
    case startupRead
    case journalAppend
    case revisionWrite
}
