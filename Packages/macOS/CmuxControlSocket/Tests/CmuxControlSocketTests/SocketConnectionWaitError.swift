/// A server did not deliver an accepted descriptor before the test deadline.
enum SocketConnectionWaitError: Error {
    case timedOut
}
