#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation

/// Main-actor state for one full-screen changes presentation.
@MainActor
@Observable
final class MobileDiffViewerModel {
    private(set) var snapshot: MobileDiffStatusSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var partialDiffErrorMessage: String?
    private(set) var tooLargePaths: Set<String> = []
    var collapsedDirectories: Set<String> = []

    let service: MobileDiffRPCService

    init(service: MobileDiffRPCService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        partialDiffErrorMessage = nil
        defer { isLoading = false }
        do {
            snapshot = try await service.loadStatus()
            tooLargePaths = []
        } catch is CancellationError {
            return
        } catch {
            snapshot = nil
            errorMessage = Self.presentation(for: error)
        }
    }

    func toggleDirectory(_ path: String) {
        if collapsedDirectories.contains(path) {
            collapsedDirectories.remove(path)
        } else {
            collapsedDirectories.insert(path)
        }
    }

    func markTooLarge(_ paths: [String]) {
        tooLargePaths.formUnion(paths)
    }

    func markPartialDiffFailure() {
        partialDiffErrorMessage = L10n.string(
            "mobile.diff.error.partial",
            defaultValue: "Some files failed to load."
        )
    }

    func clearPartialDiffFailure() {
        partialDiffErrorMessage = nil
    }

    func expandDirectories(containing filePath: String) {
        for directory in MobileDiffPath(filePath).ancestorDirectories {
            collapsedDirectories.remove(directory)
        }
    }

    private static func presentation(for error: any Error) -> String {
        guard case let MobileShellConnectionError.rpcError(code, _) = error else {
            return L10n.string(
                "mobile.diff.error.unavailable",
                defaultValue: "Changes are unavailable right now."
            )
        }
        switch code {
        case "not_git_repository":
            return L10n.string(
                "mobile.diff.error.notGitRepository",
                defaultValue: "This workspace is not a Git repository."
            )
        case "git_error":
            return L10n.string(
                "mobile.diff.error.git",
                defaultValue: "Git could not load the workspace changes."
            )
        case "not_found":
            return L10n.string(
                "mobile.diff.error.notFound",
                defaultValue: "This workspace could not be found."
            )
        case "invalid_params":
            return L10n.string(
                "mobile.diff.error.invalidRequest",
                defaultValue: "The changes request was invalid."
            )
        default:
            return L10n.string(
                "mobile.diff.error.unavailable",
                defaultValue: "Changes are unavailable right now."
            )
        }
    }
}
#endif
