import CmuxSettingsUI
import Foundation
import Observation

/// Projects the shared Stack auth attempt into stable in-pane presentation state.
@MainActor
@Observable
final class AccountSignInModel {
    enum Phase: Equatable {
        case idle
        case loading(LoadingStage)
        case failed(Failure)
        case signedIn(AccountIdentity)
    }

    enum LoadingStage: Equatable {
        case openingBrowser
        case waiting
        case waitingSlow
        case finishing
    }

    enum Failure: Equatable {
        case cancelled
        case offline
        case network
        case timedOut
        case server
        case invalidLink
        case browserUnavailable
        case unauthorized
        case rejected
        case unknown
    }

    enum LinkCopyState: Equatable {
        case idle
        case copied
        case failed
    }

    enum BrowserOpenState: Equatable {
        case idle
        case opened
        case failed
    }

    private(set) var hasRequestedSignIn = false
    private(set) var signInURL: URL?
    private(set) var linkCopyState: LinkCopyState = .idle
    private(set) var browserOpenState: BrowserOpenState = .idle
    private(set) var isStartingSignIn = false

    @ObservationIgnored private let flow: (any AccountSignInFlow)?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(flow: (any AccountSignInFlow)?) {
        self.flow = flow
    }

    var phase: Phase {
        if let identity = flow?.currentIdentity {
            return .signedIn(identity)
        }
        if isStartingSignIn {
            return .loading(.openingBrowser)
        }
        // A pane only mirrors attempts it asked for. Embedded gates (Cloud
        // Machines) must keep showing their plain sign-in prompt while another
        // surface runs the shared attempt.
        guard hasRequestedSignIn else {
            return .idle
        }
        if flow?.isCompletingSignIn == true {
            return .loading(.finishing)
        }
        if flow?.isPresentingSignIn == true {
            return .loading(flow?.signInIsSlow == true ? .waitingSlow : .waiting)
        }
        if let failure = flow?.lastSignInFailure {
            return .failed(failure)
        }
        // The attempt ended without a recorded failure: the user canceled or
        // nothing happened. Return to the sign-in prompt instead of parking on
        // an error the user already dismissed.
        return .idle
    }

    var hasFallbackLink: Bool {
        signInURL != nil
    }

    /// Starts the initial attempt once when an automatically presented pane appears.
    func startSignInIfNeeded() {
        guard !hasRequestedSignIn else { return }
        presentSignIn()
    }

    /// Starts or resumes sign-in when the pane is explicitly presented.
    func presentSignIn() {
        guard let flow, flow.currentIdentity == nil else { return }
        hasRequestedSignIn = true
        linkCopyState = .idle
        browserOpenState = .idle
        if flow.isPresentingSignIn {
            // Another surface already has the shared attempt up. Adopt it —
            // mirror its progress and reuse its callback-bound URL — instead
            // of tearing down that popup or silently doing nothing.
            if let url = flow.activeSignInURL {
                signInURL = url
            }
            return
        }
        isStartingSignIn = true
        startTask?.cancel()
        startTask = Task { @MainActor [weak self, weak flow] in
            // Give SwiftUI one update cycle to render the launch state before
            // the system authentication session takes over.
            await Task.yield()
            guard !Task.isCancelled, let self, let flow else { return }
            self.signInURL = flow.startSignInForPane()
            self.isStartingSignIn = false
        }
    }

    func openSignInInBrowser() {
        guard let signInURL else { return }
        linkCopyState = .idle
        browserOpenState = flow?.openSignInURLInDefaultBrowser(signInURL) == true ? .opened : .failed
    }

    func copySignInLink() {
        browserOpenState = .idle
        guard let signInURL else {
            linkCopyState = .failed
            return
        }
        linkCopyState = flow?.copySignInURL(signInURL) == true ? .copied : .failed
    }
}
