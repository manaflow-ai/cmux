#if os(iOS)
import CmuxMobileBrowser
import CmuxMobileSupport

extension WorkspaceDetailView {
    func openMobileDiffFromToolbar() {
        dismissTerminalKeyboardForChrome()
        browserStore.closeBrowser(for: workspace.id.rawValue)
        isChatMode = false
        pinnedChatSessionID = nil
        let state = mobileDiffState ?? MobileDiffState()
        mobileDiffState = state
        reloadMobileDiff(state)
    }

    func reloadMobileDiff(_ state: MobileDiffState) {
        mobileDiffLoadTask?.cancel()
        state.beginLoading()
        let workspaceID = workspace.id
        mobileDiffLoadTask = Task { @MainActor in
            do {
                let document = try await store.loadMobileDiff(workspaceID: workspaceID)
                guard !Task.isCancelled, mobileDiffState === state else { return }
                state.load(document)
            } catch {
                guard !Task.isCancelled, mobileDiffState === state else { return }
                state.fail(message: L10n.string(
                    "mobile.diff.loadFailedDescription",
                    defaultValue: "Refresh and try loading the changes again."
                ))
            }
        }
    }

    func closeMobileDiff() {
        mobileDiffLoadTask?.cancel()
        mobileDiffLoadTask = nil
        mobileDiffState = nil
    }
}
#endif
