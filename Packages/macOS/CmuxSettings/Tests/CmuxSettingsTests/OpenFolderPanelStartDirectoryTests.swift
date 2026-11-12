import Foundation
import Testing
@testable import CmuxSettings

@Suite("Open Folder panel start directory")
struct OpenFolderPanelStartDirectoryTests {
    private let resolver = OpenFolderPanelStartDirectory(
        homeDirectory: "/Users/me",
        isDirectory: { ["/Users/me/workspace", "/Users/me", "/srv/code"].contains($0) }
    )

    private func resolve(_ configuredPath: String, workspaceDirectory: String? = "/active") -> String? {
        resolver.resolve(configuredPath: configuredPath, workspaceDirectory: workspaceDirectory)?.path
    }

    @Test func configuredPathWinsWhenItIsAnExistingFolder() {
        #expect(resolve("~/workspace") == "/Users/me/workspace")
        #expect(resolve("  ~/workspace\n") == "/Users/me/workspace")
        #expect(resolve("~") == "/Users/me")
        #expect(resolve("/srv/code") == "/srv/code")
    }

    @Test func fallsBackToTheActiveWorkspaceDirectory() {
        #expect(resolve("") == "/active")
        #expect(resolve("~/missing") == "/active")
        #expect(resolve("relative/path") == "/active")
        #expect(resolve("~other/code") == "/active")
    }

    @Test func returnsNilWithNoUsableDirectory() {
        #expect(resolve("", workspaceDirectory: nil) == nil)
        #expect(resolve("~/missing", workspaceDirectory: "") == nil)
    }

    @Test func defaultsToEmpty() {
        #expect(AppCatalogSection().defaultWorkspacePath.defaultValue.isEmpty)
    }
}
