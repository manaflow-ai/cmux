import AppKit
import CmuxDockExtensions
import Foundation
import Observation

/// Drives the consent flow for extension installs and updates from every
/// entrypoint: resolve + stage the preview, show the consent window, and on
/// confirmation execute the consented preview. One flow at a time; nothing
/// from the extension runs before ``confirm()``.
@MainActor
@Observable
final class ExtensionInstallCoordinator {
    /// The consent window's current content.
    enum Phase: Equatable {
        /// Nothing in flight (window closed).
        case idle
        /// Collecting the `owner/repo` input.
        case prompting
        /// Resolving the ref and staging the checkout for `input`.
        case loading(input: String)
        /// Awaiting the user's decision on a staged preview.
        case consent(DockExtensionInstallPreview)
        /// Executing a confirmed preview (build + move + record).
        case installing(DockExtensionInstallPreview)
        /// Terminal failure.
        case failed(message: String)
        /// Success; `openPaneQualifiedId` offers a one-click open when the
        /// extension has exactly one pane.
        case installed(name: String, openPaneQualifiedId: String?)
    }

    private(set) var phase: Phase = .idle
    private let store: DockExtensionsStore

    init(store: DockExtensionsStore) {
        self.store = store
    }

    /// Whether a resolve/install is currently running (buttons disable).
    var isWorking: Bool {
        switch phase {
        case .loading, .installing: return true
        case .idle, .prompting, .consent, .failed, .installed: return false
        }
    }

    /// Opens the consent window on the input prompt (palette "Install from
    /// GitHub…"). If a flow is already showing, just brings it forward.
    func promptForInstall() {
        if case .idle = phase {
            phase = .prompting
        }
        ExtensionConsentWindowController.shared.show()
    }

    /// Starts an install flow for `owner/repo[/subdir]` input.
    func beginInstall(input: String, ref: String? = nil) {
        guard !isWorking else {
            ExtensionConsentWindowController.shared.show()
            return
        }
        if case .consent(let pending) = phase {
            store.discard(pending)
        }
        phase = .loading(input: input)
        ExtensionConsentWindowController.shared.show()
        Task { @MainActor in
            do {
                let preview = try await store.previewInstall(input: input, ref: ref)
                phase = .consent(preview)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Starts an update flow for an installed extension id.
    func beginUpdate(id: String) {
        guard !isWorking else {
            ExtensionConsentWindowController.shared.show()
            return
        }
        if case .consent(let pending) = phase {
            store.discard(pending)
        }
        phase = .loading(input: id)
        ExtensionConsentWindowController.shared.show()
        Task { @MainActor in
            do {
                let preview = try await store.previewUpdate(id: id)
                phase = .consent(preview)
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Executes the staged preview the user approved.
    func confirm() {
        guard case .consent(let preview) = phase else { return }
        phase = .installing(preview)
        Task { @MainActor in
            do {
                try await store.install(preview)
                // GUI install: reveal the Dock so the user sees where panes
                // live. Socket/CLI installs skip this (focus policy); their
                // reveal happens only on explicit `extension open`.
                AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .dock,
                    focusFirstItem: false
                )
                let panes = preview.manifest.panesForCurrentPlatform
                let openPaneQualifiedId = panes.count == 1
                    ? panes.first.map {
                        DockExtensionPane.qualifiedId(extensionId: preview.manifest.id, paneId: $0.id)
                    }
                    : nil
                phase = .installed(
                    name: preview.manifest.name,
                    openPaneQualifiedId: openPaneQualifiedId
                )
            } catch {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Cancels the flow, discarding any staged checkout, and closes the window.
    func cancel() {
        if case .consent(let preview) = phase {
            store.discard(preview)
        }
        phase = .idle
        ExtensionConsentWindowController.shared.closeWindow()
    }

    /// Dismisses a terminal (failed/installed) state.
    func dismiss() {
        phase = .idle
        ExtensionConsentWindowController.shared.closeWindow()
    }

    /// Window-close (red button / Cmd+W) handling: treat like cancel so a
    /// pending staged checkout never leaks.
    func handleWindowClosed() {
        if case .consent(let preview) = phase {
            store.discard(preview)
        }
        if isWorking { return } // Let an in-flight install finish; reload reconciles.
        phase = .idle
    }
}
