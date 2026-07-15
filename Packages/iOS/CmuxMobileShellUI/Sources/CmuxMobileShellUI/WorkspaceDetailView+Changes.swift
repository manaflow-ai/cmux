import CmuxMobileDiff
import CmuxMobileRPC
import CmuxMobileSupport
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    /// The one presentation mutation used by toolbar and debug placements.
    func presentChanges(
        scrollToPath: String? = nil,
        baseSpec: MobileChangesBaseSpec = MobileChangesBaseSpec(kind: .workingTree)
    ) {
        guard store.supportsWorkspaceChanges else { return }
        changesPresentation = WorkspaceChangesPresentation(
            scrollToPath: scrollToPath,
            baseSpec: baseSpec
        )
    }

    var changesToolbarButton: some View {
        Button {
            presentChanges()
        } label: {
            Image(systemName: "plus.forwardslash.minus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.changes", defaultValue: "Changes"))
        .accessibilityIdentifier("MobileWorkspaceChangesButton")
    }

    var changesNavigationIsPresented: Binding<Bool> {
        Binding(
            get: { changesPresentation != nil },
            set: { isPresented in
                if !isPresented { changesPresentation = nil }
            }
        )
    }

    @ViewBuilder
    func changesDestination() -> some View {
        if let presentation = changesPresentation,
           let service = store.makeChangesService(workspaceID: workspace.id) {
            ChangesScreen(
                service: service,
                workspace: ChangesWorkspaceContext(
                    workspaceID: workspace.id.rawValue,
                    displayName: workspace.name
                ),
                baseSpec: presentation.baseSpec,
                scrollToPath: presentation.scrollToPath,
                navigationModel: displaySettings.diffNavigationModel,
                layoutPreference: displaySettings.diffLayoutPreference,
                setLayoutPreference: { displaySettings.diffLayoutPreference = $0 },
                sendToAgent: changesSendAction,
                editInComposer: changesComposerAction
            )
        } else {
            ContentUnavailableView(
                L10n.string("mobile.changes.unavailable.title", defaultValue: "Changes unavailable"),
                systemImage: "wifi.exclamationmark",
                description: Text(L10n.string(
                    "mobile.changes.unavailable.message",
                    defaultValue: "Reconnect to your Mac and try again."
                ))
            )
        }
    }

    private var changesSendAction: (@MainActor (String) async throws -> Void)? {
        guard canRouteChangesToAgent else { return nil }
        return { prompt in try await sendChangesPrompt(prompt) }
    }

    private var changesComposerAction: (@MainActor (String) -> Void)? {
        guard canRouteChangesToAgent else { return nil }
        return { prompt in editChangesPromptInComposer(prompt) }
    }
}
#endif
