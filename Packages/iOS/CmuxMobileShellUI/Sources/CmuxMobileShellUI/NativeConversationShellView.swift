import CmuxConversationUI
import CmuxMobileShell
import SwiftUI

/// The shell owns account/host routing; the conversation feature only receives
/// its scoped client and explicit workspace choices.
struct NativeConversationShellView: View {
    @Bindable var shellStore: MobileShellComposite
    let model: ConversationModel
    @State private var storageError: String?

    private var workspaceChoices: [ConversationWorkspaceChoice] {
        shellStore.conversationWorkspaces.map {
            ConversationWorkspaceChoice(id: $0.rpcWorkspaceID.rawValue, title: $0.name, directory: $0.currentDirectory ?? "")
        }
    }

    var body: some View {
        ConversationRootView(model: model, embedsNavigationStack: false)
            .safeAreaInset(edge: .bottom) {
                if let storageError {
                    Text(storageError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .onChange(of: workspaceChoices, initial: true) { _, choices in
                model.workspaces = choices
                let currentID = model.newTaskWorkspace?.id
                let foregroundID = shellStore.explicitlySelectedWorkspace?.rpcWorkspaceID.rawValue
                model.newTaskWorkspace = choices.first { $0.id == currentID }
                    ?? choices.first { $0.id == foregroundID }
                    ?? choices.first
            }
            .task(id: shellStore.conversationConnectionKey) {
                let scope = shellStore.conversationScopeID ?? "signed-out"
                do {
                    let client = try shellStore.makeConversationClient()
                    model.replaceClient(client, scopeID: scope)
                    storageError = nil
                } catch {
                    model.replaceClient(nil, scopeID: scope)
                    storageError = String(localized: "conversation.error.storage", defaultValue: "Saved command status could not be read. Tasks are paused to protect unsent work.", bundle: .module)
                }
            }
    }
}
