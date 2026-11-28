#if DEBUG && os(iOS)
import CmuxMobileAgentChat
import SwiftUI

/// `-cmux-mobile-recovery-gallery githubsignin`: Sign in with GitHub as a Cloud machine's New Chat
/// draws it (`CloudChatsScreen`), for the PR's screenshot: a start refused with no login on the
/// phone, one whose carried login can't reach the repository, and a chat's GitHub call refused
/// while the App's updated permissions wait.
struct GitHubSignInGallery: View {
    private static let needs: [GitHubSignInNeed] = [
        GitHubSignInNeed(startCode: GitHubSignInNeed.cloneCode,
                         details: .object(["repo": .string("acme/web"), "githubLogin": .string("none")]))!,
        GitHubSignInNeed(startCode: GitHubSignInNeed.cloneCode,
                         details: .object(["repo": .string("acme/web"), "githubLogin": .string("carried"), "githubUser": .string("octo")]))!,
        GitHubSignInNeed(reason: .permissionsPending, repo: "acme/web"),
    ]

    var body: some View {
        NavigationStack {
            List {
                // visible-only: three fixed gallery cards.
                ForEach(Self.needs, id: \.self) { need in
                    GitHubSignInCard(need: need) {}
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
                Text(verbatim: "Tap New Chat to start one on this Cloud machine.").foregroundStyle(.secondary)
            }
            .navigationTitle(Text(verbatim: "cloud-dev-1"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Chat", systemImage: "square.and.pencil") {}
                }
            }
        }
        // The button is live in the gallery: it waits a moment and comes back.
        .onAppear {
            if GitHubSignInHook.run == nil {
                GitHubSignInHook.run = { _ in
                    try? await Task.sleep(for: .seconds(2))
                    return false
                }
            }
        }
    }
}
#endif
