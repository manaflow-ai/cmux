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
                state.fail(message: mobileDiffLoadFailureMessage(store.mobileDiffLoadErrorCode(for: error)))
            }
        }
    }

    func closeMobileDiff() {
        mobileDiffLoadTask?.cancel()
        mobileDiffLoadTask = nil
        mobileDiffState = nil
    }

    private func mobileDiffLoadFailureMessage(_ code: String?) -> String {
        if let code {
            switch code {
            case "not_found":
                return L10n.string(
                    "mobile.diff.notGitRepository",
                    defaultValue: "This workspace isn’t inside a Git repository."
                )
            case "too_large":
                return L10n.string(
                    "mobile.diff.tooLarge",
                    defaultValue: "This diff is too large to view on this phone."
                )
            case "too_many_files":
                return L10n.string(
                    "mobile.diff.tooManyFiles",
                    defaultValue: "This workspace has too many untracked files to view on this phone."
                )
            case "invalid_data":
                return L10n.string(
                    "mobile.diff.invalidData",
                    defaultValue: "This diff contains text the mobile viewer can’t display."
                )
            default:
                break
            }
        }
        return L10n.string(
            "mobile.diff.loadFailedDescription",
            defaultValue: "Refresh and try loading the changes again."
        )
    }
}
#endif
