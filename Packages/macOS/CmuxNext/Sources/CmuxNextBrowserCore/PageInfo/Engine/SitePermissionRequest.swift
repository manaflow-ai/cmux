import CmuxSafeConcurrency
package import Foundation

/// A site's request for a permission the prompt bar asks about (camera and
/// microphone, location, notifications), in either engine: answered from the
/// shared store, asking only when the site has no decision, and the answer
/// stored ("Allow this time" stores nothing).
package struct SitePermissionRequest {
    package enum Outcome: Equatable {
        case grant
        case deny
        /// The question went away unanswered (the tab closed, Chromium
        /// ended it); nothing is stored.
        case dismiss
    }

    package let kind: BrowserPermissionKind
    package let origin: String
    package let store: SitePermissionStore

    /// `ask` is the tab's `enqueuePrompt`; `done` runs once.
    package func decide(ask: @escaping @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void,
                done: @escaping @MainActor (Outcome) -> Void) {
        // Automatic downloads have their own gate (`AutomaticDownloadGate`).
        guard kind != .automaticDownloads else { return done(.deny) }
        let kinds = kind.siteKinds
        let (kind, origin, store) = (kind, origin, store)
        // main-hop-allow: one main-actor chain per request: the store's one file read (whenLoaded) and the prompt's answer each resume on main, where the store and the prompt bar live
        Task {
            await store.whenLoaded()
            let settings = kinds.map { store.setting($0, for: origin) }
            let outcome: Outcome
            if settings.contains(.block) {
                outcome = .deny
            } else if !settings.isEmpty, settings.allSatisfy({ $0 == .allow }) {
                outcome = .grant
            } else {
                // A prompt dropped unanswered (a closing tab answers its prompts, so never) dismisses.
                let response = try? await withOnceContinuation { (answered: OnceContinuation<BrowserPromptResponse, OnceContinuationError>) in
                    ask(.permission(kind), origin) { answered.resume(returning: $0) }
                }
                switch response ?? .cancel {
                case .allow:
                    kinds.forEach { store.set(.allow, $0, for: origin) }
                    outcome = .grant
                case .deny:
                    kinds.forEach { store.set(.block, $0, for: origin) }
                    outcome = .deny
                case .allowOnce: outcome = .grant
                default: outcome = .dismiss
                }
            }
            done(outcome)
        }
    }

    package init(kind: BrowserPermissionKind, origin: String, store: SitePermissionStore) {
        self.kind = kind
        self.origin = origin
        self.store = store
    }
}

extension BrowserPermissionKind {
    /// The per-site settings that decide it (automatic downloads have their
    /// own gate, `AutomaticDownloadGate`).
    package var siteKinds: Set<SitePermissionKind> {
        switch self {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        case .location: [.location]
        case .notifications: [.notifications]
        case .automaticDownloads: []
        }
    }
}
