import Foundation
import Testing
@testable import CmuxSettings

@Suite("Open Folder panel start directory")
struct OpenFolderPanelStartDirectoryTests {
    private let environment = ["CODE": "/Users/me/code"]
    private let existingDirectories: Set<String> = ["/Users/me/workspace", "/Users/me/code/app"]

    private func resolve(_ configuredPath: String, workspaceDirectory: String? = "/active") -> String? {
        OpenFolderPanelStartDirectory.resolve(
            configuredPath: configuredPath,
            workspaceDirectory: workspaceDirectory,
            environment: environment,
            homeDirectory: "/Users/me",
            isDirectory: { existingDirectories.contains($0) }
        )?.path
    }

    @Test func configuredPathWinsWhenItIsAnExistingFolder() {
        #expect(resolve("~/workspace") == "/Users/me/workspace")
        #expect(resolve("  ~/workspace\n") == "/Users/me/workspace")
        #expect(resolve("$CODE/app") == "/Users/me/code/app")
        #expect(resolve("${CODE}/app") == "/Users/me/code/app")
    }

    @Test func fallsBackToTheActiveWorkspaceDirectory() {
        #expect(resolve("") == "/active")
        #expect(resolve("~/missing") == "/active")
        #expect(resolve("$UNSET/app") == "/active")
        #expect(resolve("relative/path") == "/active")
    }

    @Test func returnsNilWithNoUsableDirectory() {
        #expect(resolve("", workspaceDirectory: nil) == nil)
        #expect(resolve("~/missing", workspaceDirectory: "") == nil)
    }

    @Test func defaultsToEmpty() {
        #expect(AppCatalogSection().defaultWorkspacePath.defaultValue.isEmpty)
    }
}
