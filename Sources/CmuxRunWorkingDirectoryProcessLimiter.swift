import Foundation

actor CmuxRunWorkingDirectoryProcessLimiter {
    struct Permit: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    enum Acquisition: Equatable, Sendable {
        case acquired(Permit)
        case busy
        case unavailable
    }

    private enum State {
        case idle
        case running(Permit)
        case unavailable(Permit)
    }

    private var state = State.idle

    func acquire() -> Acquisition {
        switch state {
        case .idle:
            let permit = Permit()
            state = .running(permit)
            return .acquired(permit)
        case .running:
            return .busy
        case .unavailable:
            return .unavailable
        }
    }

    func markUnavailable(_ permit: Permit) {
        guard case .running(let activePermit) = state,
              activePermit == permit else { return }
        state = .unavailable(permit)
    }

    func recordTermination(_ permit: Permit) {
        switch state {
        case .running(let activePermit), .unavailable(let activePermit):
            guard activePermit == permit else { return }
            state = .idle
        case .idle:
            break
        }
    }
}
