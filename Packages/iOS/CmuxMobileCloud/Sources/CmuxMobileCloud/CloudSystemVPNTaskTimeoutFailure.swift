extension CloudSystemVPNTaskTimeout {
    enum Failure: Error, Sendable, Equatable {
        case timedOut
    }
}
