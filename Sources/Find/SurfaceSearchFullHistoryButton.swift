import SwiftUI

/// The find bar's button that loads a mirrored pane's whole tmux history.
struct SurfaceSearchFullHistoryButton: View {
    let search: RemoteTmuxFullHistorySearch

    var body: some View {
        Button(action: {
            Task { @MainActor in await search.load() }
        }) {
            if search.state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: symbolName)
            }
        }
        .buttonStyle(SearchButtonStyle())
        .disabled(search.state == .loading)
        .safeHelp(help)
        .accessibilityIdentifier("TerminalFindFullTmuxHistoryButton")
    }

    private var symbolName: String {
        switch search.state {
        case .notLoaded, .loading: return "clock.arrow.circlepath"
        case .loaded: return "checkmark.circle"
        case .alternateScreen: return "rectangle.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var help: String {
        switch search.state {
        case .notLoaded:
            return String(
                localized: "search.fullTmuxHistory.help",
                defaultValue: "Search full tmux history (Option-Return)"
            )
        case .loading:
            return String(
                localized: "search.fullTmuxHistory.loading.help",
                defaultValue: "Loading tmux history…"
            )
        case .loaded(_, let truncated):
            return truncated
                ? String(
                    localized: "search.fullTmuxHistory.truncated.help",
                    defaultValue: "Loaded the newest part of this pane's tmux history. Click to load it again."
                )
                : String(
                    localized: "search.fullTmuxHistory.loaded.help",
                    defaultValue: "Searching this pane's full tmux history. Click to load it again."
                )
        case .alternateScreen:
            return String(
                localized: "search.fullTmuxHistory.alternateScreen.help",
                defaultValue: "This pane is showing a full-screen app, which has no tmux history"
            )
        case .failed:
            return String(
                localized: "search.fullTmuxHistory.failed.help",
                defaultValue: "Couldn't load tmux history. Click to try again."
            )
        }
    }
}
