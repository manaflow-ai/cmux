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
        if hasRequestedSignIn, flow?.isCompletingSignIn == true {
            return .loading(.finishing)
        }
        if flow?.isPresentingSignIn == true {
            return .loading(flow?.signInIsSlow == true ? .waitingSlow : .waiting)
        }
        if hasRequestedSignIn {
            return .failed(flow?.lastSignInFailure ?? .cancelled)
        }
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
        guard let flow, flow.currentIdentity == nil, !flow.isPresentingSignIn else { return }
        hasRequestedSignIn = true
        linkCopyState = .idle
        browserOpenState = .idle
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
