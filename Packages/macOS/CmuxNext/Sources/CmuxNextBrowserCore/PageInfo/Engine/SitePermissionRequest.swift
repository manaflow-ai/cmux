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

    /// `ask` is the tab's `enqueuePrompt`; `done` runs once. Once the store's file is read (every request after the
    /// profile's first) it decides in the request's own turn, as Chrome's PermissionRequestManager answers a stored
    /// decision synchronously (components/permissions/permission_request_manager.cc).
    package func decide(ask: @escaping @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void,
                done: @escaping @MainActor (Outcome) -> Void) {
        let kinds = kind.siteKinds
        guard !kinds.isEmpty else { return done(.deny) }
        guard !store.isLoaded else { return Self.decide(kind, kinds, origin, store, ask: ask, done: done) }
        let (kind, origin, store) = (kind, origin, store)
        // main-hop-allow: whenLoaded is the permission store's main-actor wait for its one file read (only the profile's first requests reach it); the decision is made in its resume
        Task {
            await store.whenLoaded()
            Self.decide(kind, kinds, origin, store, ask: ask, done: done)
        }
    }

    /// The stored decision, or the prompt's answer (stored unless "Allow this time").
    private static func decide(_ kind: BrowserPermissionKind, _ kinds: Set<SitePermissionKind>, _ origin: String,
                               _ store: SitePermissionStore,
                               ask: @MainActor (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void,
                               done: @escaping @MainActor (Outcome) -> Void) {
        let settings = kinds.map { store.setting($0, for: origin) }
        if settings.contains(.block) { return done(.deny) }
        if settings.allSatisfy({ $0 == .allow }) { return done(.grant) }
        ask(.permission(kind), origin) { response in
            switch response {
            case .allow:
                kinds.forEach { store.set(.allow, $0, for: origin) }
                done(.grant)
            case .deny:
                kinds.forEach { store.set(.block, $0, for: origin) }
                done(.deny)
            case .allowOnce: done(.grant)
            default: done(.dismiss)
            }
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
