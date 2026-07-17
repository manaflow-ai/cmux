#if DEBUG
import CmuxMobileShell
import SwiftUI

/// Standalone Dispatch composer fixture (`CMUX_UITEST_DISPATCH_PREVIEW=1`):
/// a stub service with a canned catalog and directory tree so layout and flow
/// screenshots need no sign-in or paired Mac. Briefs containing "fail"
/// exercise the REJECTED stamp; anything else stamps DISPATCHED.
struct DispatchComposerPreviewView: View {
    @State private var visible = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $visible) {
                DispatchComposerSheet(
                    service: DispatchPreviewService(),
                    willLaunch: {},
                    launchFailed: {},
                    finished: { visible = false }
                )
            }
    }
}

@MainActor
private final class DispatchPreviewService: DispatchComposerServicing {
    var dispatchHostName: String? { "Preview Mac" }
    var dispatchIsConnected: Bool { true }
    var dispatchMacKey: String { "dispatch-preview" }

    private let home = "/Users/preview"

    func dispatchCatalog() async throws -> DispatchCatalog {
        DispatchCatalog(
            home: home,
            agents: [
                DispatchAgent(id: "claude", name: "Claude Code", installed: true),
                DispatchAgent(id: "codex", name: "Codex", installed: false),
            ],
            recentDirectories: [
                DispatchDirectory(path: home + "/Dev/cmux", git: true),
                DispatchDirectory(path: home + "/Dev/zed", git: true),
                DispatchDirectory(path: home + "/Notes", git: false),
            ],
            promptByteBudget: 900
        )
    }

    func dispatchFSList(path: String, includeHidden: Bool) async throws -> DispatchFSList {
        var entries = [
            DispatchDirectory(path: path + "/Alpha", git: false),
            DispatchDirectory(path: path + "/cmux", git: true),
            DispatchDirectory(path: path + "/Documents", git: false),
            DispatchDirectory(path: path + "/Notes", git: false),
        ]
        if includeHidden {
            entries.insert(DispatchDirectory(path: path + "/.config", git: false), at: 0)
        }
        if path.hasSuffix("Documents") {
            return DispatchFSList(
                path: path,
                entries: [],
                notice: DispatchFSNotice(code: "permission_denied", message: "Operation not permitted"),
                truncated: false
            )
        }
        return DispatchFSList(path: path, entries: entries, notice: nil, truncated: false)
    }

    func dispatchFSSearch(query: String) async throws -> DispatchFSSearch {
        let all = [
            DispatchDirectory(path: home + "/Dev/cmux", git: true),
            DispatchDirectory(path: home + "/Dev/cmux-cua", git: true),
            DispatchDirectory(path: home + "/Downloads/cmyk-assets", git: false),
        ]
        let entries = all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return DispatchFSSearch(query: query, entries: entries, indexing: false, truncated: false)
    }

    func dispatchLaunch(directory: String, agentID: String, prompt: String) async -> Result<Void, DispatchLaunchFailure> {
        try? await ContinuousClock().sleep(for: .milliseconds(700))
        if prompt.localizedCaseInsensitiveContains("fail") {
            return .failure(.agentNotInstalled)
        }
        return .success(())
    }
}
#endif
