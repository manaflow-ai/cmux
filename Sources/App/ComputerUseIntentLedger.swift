import Foundation

extension ComputerUseIntentBoundary {
    /// Tracks one-flight onboarding claims without coupling the gate to a
    /// window, helper process, or clock.
    struct Ledger: Equatable, Sendable {
        enum Completion: Sendable {
            case handled
            case retry
        }

        struct Claim: Equatable, Sendable {
            let signal: Signal
            fileprivate let generation: UInt64
        }

        private struct SessionState: Equatable, Sendable {
            var generation: UInt64 = 0
            var turnClaimed = false
            var inFlightToken: String?
            var turnEnded = false
            var handledRequestTokens: Set<String> = []
            var lastPromptToken: String?
            var lastTouched: UInt64 = 0
        }

        private var states: [Session: SessionState] = [:]
        private var touchCounter: UInt64 = 0
        private static let maximumSessionCount = 64

        /// Applies one lifecycle observation and returns a new claim, if any.
        mutating func observe(_ observation: Observation) -> Claim? {
            switch observation {
            case .ignored:
                return nil
            case .turnStarted(let turn):
                var state = states[turn.session] ?? SessionState()
                let isNewTurn = turn.token == nil || state.lastPromptToken != turn.token
                if isNewTurn {
                    state.generation &+= 1
                    state.turnClaimed = false
                    state.inFlightToken = nil
                    state.turnEnded = false
                    state.handledRequestTokens.removeAll()
                    state.lastPromptToken = turn.token
                }
                touch(&state)
                states[turn.session] = state
                trimIfNeeded()
                guard let signal = turn.signal else { return nil }
                return claim(signal, in: state)
            case .request(let signal):
                let state = states[signal.session] ?? SessionState()
                return claim(signal, in: state)
            case .completed(let session):
                guard var state = states[session] else { return nil }
                state.turnClaimed = false
                // Keep an in-flight claim alive until its probe finishes; a
                // delayed duplicate must not slip through the completion
                // boundary while the original request is still evaluating.
                state.turnEnded = true
                touch(&state)
                states[session] = state
                return nil
            }
        }

        /// Reconciles a claim after the asynchronous permission probe/present.
        mutating func finish(_ claim: Claim, completion: Completion) {
            guard var state = states[claim.signal.session],
                  state.generation == claim.generation
            else {
                return
            }
            if state.inFlightToken == claim.signal.requestToken {
                state.inFlightToken = nil
            }
            switch completion {
            case .handled:
                state.handledRequestTokens.insert(claim.signal.requestToken)
                state.turnClaimed = !state.turnEnded
            case .retry:
                state.turnClaimed = false
            }
            touch(&state)
            states[claim.signal.session] = state
        }

        mutating func clear() {
            states.removeAll()
            touchCounter = 0
        }

        private mutating func claim(
            _ signal: Signal,
            in incomingState: SessionState
        ) -> Claim? {
            var state = incomingState
            guard
                state.inFlightToken == nil,
                !state.turnClaimed,
                !state.handledRequestTokens.contains(signal.requestToken)
            else {
                return nil
            }
            state.turnEnded = false
            state.inFlightToken = signal.requestToken
            touch(&state)
            states[signal.session] = state
            trimIfNeeded()
            return Claim(signal: signal, generation: state.generation)
        }

        private mutating func touch(_ state: inout SessionState) {
            touchCounter &+= 1
            state.lastTouched = touchCounter
        }

        private mutating func trimIfNeeded() {
            guard states.count > Self.maximumSessionCount else { return }
            guard let oldest = states.min(by: {
                $0.value.lastTouched < $1.value.lastTouched
            })?.key else {
                return
            }
            states.removeValue(forKey: oldest)
        }
    }
}
