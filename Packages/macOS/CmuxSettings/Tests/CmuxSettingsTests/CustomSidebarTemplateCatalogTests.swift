import Foundation
import Testing
@testable import CmuxSettings

@Suite
struct CustomSidebarTemplateCatalogTests {
    @Test
    func bundledManifestMatchesExamplesFolder() throws {
        let catalog = CustomSidebarTemplateCatalog()
        let examplesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/CustomSidebars", isDirectory: true)
        let exampleFiles = try FileManager.default.contentsOfDirectory(
            at: examplesDirectory,
            includingPropertiesForKeys: nil
        ).filter { ["js", "swift", "json"].contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .filter { $0 != "manifest.json" }
            .sorted()
        let bundledFiles = catalog.templates.map(\.file).sorted()
        #expect(bundledFiles == exampleFiles)
        #expect(catalog.templates.count == 19)
        for descriptor in catalog.templates {
            #expect(catalog.template(id: descriptor.id)?.source.isEmpty == false)
            #expect(CustomSidebarTemplateCatalog.isValidInstallationName(descriptor.id))
        }
    }

    @Test(arguments: ["agents-board", "panel-info", "status-board"])
    func metadataIsAvailable(id: String) throws {
        let descriptor = try #require(CustomSidebarTemplateCatalog().templates.first { $0.id == id })
        #expect(!descriptor.displayName.isEmpty)
        #expect(!descriptor.description.isEmpty)
        #expect([.left, .right, .both].contains(descriptor.kind))
    }

    @Test(arguments: ["agents_board", "../agents-board", "", "Agents-Board", "agents-board/"])
    func rejectsUnsafeInstallationNames(name: String) {
        #expect(!CustomSidebarTemplateCatalog.isValidInstallationName(name))
    }
}

@Suite
struct CustomSidebarTemplateInstallerTests {
    @Test
    func copiesTemplateAndRefusesOverwriteUntilForced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = CustomSidebarTemplateInstaller()
        let first = try installer.install(name: "my-agents", templateID: "agents-board", directory: root)
        #expect(first.pathExtension == "js")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(throws: CustomSidebarTemplateInstallError.alreadyExists) {
            try installer.install(name: "my-agents", templateID: "agents-board", directory: root)
        }
        let forced = try installer.install(name: "my-agents", templateID: "clock", directory: root, force: true)
        #expect(forced.pathExtension == "swift")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("my-agents.js").path))
    }

    @Test(arguments: ["../escape", "bad_name", "Bad-name", "bad/name"])
    func rejectsInvalidNames(_ name: String) {
        #expect(throws: CustomSidebarTemplateInstallError.invalidName) {
            try CustomSidebarTemplateInstaller().install(
                name: name,
                templateID: "agents-board",
                directory: FileManager.default.temporaryDirectory
            )
        }
    }

    @Test
    func rejectsUnknownTemplate() {
        #expect(throws: CustomSidebarTemplateInstallError.unknownTemplate) {
            try CustomSidebarTemplateInstaller().install(
                name: "unknown",
                templateID: "does-not-exist",
                directory: FileManager.default.temporaryDirectory
            )
        }
    }
}
