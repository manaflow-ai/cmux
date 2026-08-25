/// Errors that keep an incomplete or misrouted replay from becoming live.
enum HiveRemoteTerminalSessionError: Error {
    case missingFrame
    case incompleteFrame
    case mismatchedSurface
}
