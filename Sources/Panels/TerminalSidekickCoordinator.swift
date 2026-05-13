import Foundation
import Combine

nonisolated struct TerminalSidekickState: Codable, Equatable, Sendable {
    static let defaultSplitRatio = 0.4
    private static let minimumSplitRatio = 0.25
    private static let maximumSplitRatio = 0.7

    var urlString: String?
    var isOpen: Bool
    var splitRatio: Double

    init(
        urlString: String? = nil,
        isOpen: Bool = false,
        splitRatio: Double = Self.defaultSplitRatio
    ) {
        self.urlString = Self.normalizedURLString(urlString)
        self.isOpen = isOpen
        self.splitRatio = Self.clampedSplitRatio(splitRatio)
    }

    static func clampedSplitRatio(_ value: Double) -> Double {
        min(max(value, minimumSplitRatio), maximumSplitRatio)
    }

    static func normalizedURLString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var url: URL? {
        urlString.flatMap(URL.init(string:))
    }

    var hasPersistableValue: Bool {
        isOpen ||
            urlString != nil ||
            abs(splitRatio - Self.defaultSplitRatio) > 0.0001
    }
}

@MainActor
final class TerminalSidekickCoordinator {
    private(set) var state = TerminalSidekickState()
    private(set) var browserPanel: BrowserPanel?

    private var workspaceId: UUID
    private let notifyChanged: @MainActor () -> Void
    private var browserPanelCancellable: AnyCancellable?

    init(
        workspaceId: UUID,
        notifyChanged: @MainActor @escaping () -> Void
    ) {
        self.workspaceId = workspaceId
        self.notifyChanged = notifyChanged
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        browserPanel?.updateWorkspaceId(newWorkspaceId)
    }

    @discardableResult
    func toggleSidekick() -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }
        if state.isOpen {
            closeSidekick()
            return true
        }
        return openSidekick()
    }

    @discardableResult
    func openSidekick(url: URL? = nil) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }
        guard let browserPanel = ensureBrowserPanel(renderInitialNavigation: url == nil) else { return false }

        var next = state
        next.isOpen = true
        if let url {
            next.urlString = url.absoluteString
        }
        replaceState(next)

        if let url {
            browserPanel.navigate(to: url, recordTypedNavigation: true)
        }
        return true
    }

    func closeSidekick() {
        var next = state
        next.urlString = currentURLString()
        next.isOpen = false
        replaceState(next)
        closeBrowserPanel()
    }

    func navigateSidekick(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard BrowserAvailabilitySettings.isEnabled() else { return }
        guard let browserPanel = ensureBrowserPanel(renderInitialNavigation: false) else { return }
        var next = state
        next.isOpen = true
        replaceState(next)
        browserPanel.navigateSmart(trimmed)
    }

    func recordSidekickCurrentURL(_ url: URL?) {
        let nextURLString = TerminalSidekickState.normalizedURLString(url?.absoluteString)
        guard state.urlString != nextURLString else { return }
        var next = state
        next.urlString = nextURLString
        replaceState(next)
    }

    func setSidekickSplitRatio(_ splitRatio: Double) {
        let clamped = TerminalSidekickState.clampedSplitRatio(splitRatio)
        guard state.splitRatio != clamped else { return }
        var next = state
        next.splitRatio = clamped
        replaceState(next)
    }

    func restoreSidekick(_ snapshot: SessionTerminalSidekickSnapshot?) {
        guard let snapshot else {
            replaceState(TerminalSidekickState())
            closeBrowserPanel()
            return
        }

        replaceState(
            TerminalSidekickState(
                urlString: snapshot.urlString,
                isOpen: snapshot.isOpen,
                splitRatio: snapshot.splitRatio
            )
        )

        guard BrowserAvailabilitySettings.isEnabled() else {
            var next = state
            next.isOpen = false
            replaceState(next)
            closeBrowserPanel()
            return
        }

        if state.isOpen {
            let hadBrowserPanel = browserPanel != nil
            guard let browserPanel = ensureBrowserPanel() else {
                var next = state
                next.isOpen = false
                replaceState(next)
                return
            }
            if hadBrowserPanel, let url = state.url {
                browserPanel.navigate(to: url, recordTypedNavigation: false)
            }
        }
    }

    func sessionSnapshot() -> SessionTerminalSidekickSnapshot? {
        let urlString = currentURLString()
        let snapshotState = TerminalSidekickState(
            urlString: urlString,
            isOpen: state.isOpen,
            splitRatio: state.splitRatio
        )
        guard snapshotState.hasPersistableValue else { return nil }
        return SessionTerminalSidekickSnapshot(
            urlString: snapshotState.urlString,
            isOpen: snapshotState.isOpen,
            splitRatio: snapshotState.splitRatio
        )
    }

    func closeBrowserPanel() {
        browserPanel?.close()
        replaceBrowserPanel(nil)
    }

    private func currentURLString() -> String? {
        TerminalSidekickState.normalizedURLString(
            browserPanel?.preferredURLStringForOmnibar() ?? state.urlString
        )
    }

    private func observeBrowserPanelChanges() {
        browserPanelCancellable = browserPanel?.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.notifyChanged()
            }
        }
    }

    @discardableResult
    private func ensureBrowserPanel(renderInitialNavigation: Bool = true) -> BrowserPanel? {
        if let browserPanel {
            return browserPanel
        }

        let browserPanel = BrowserPanel(
            workspaceId: workspaceId,
            initialURL: state.url,
            renderInitialNavigation: renderInitialNavigation && state.url != nil
        )
        replaceBrowserPanel(browserPanel)
        return browserPanel
    }

    private func replaceState(_ next: TerminalSidekickState) {
        guard state != next else { return }
        notifyChanged()
        state = next
    }

    private func replaceBrowserPanel(_ next: BrowserPanel?) {
        if browserPanel == nil, next == nil {
            return
        }
        if let browserPanel, let next, browserPanel === next {
            return
        }

        notifyChanged()
        browserPanel = next
        observeBrowserPanelChanges()
    }
}
