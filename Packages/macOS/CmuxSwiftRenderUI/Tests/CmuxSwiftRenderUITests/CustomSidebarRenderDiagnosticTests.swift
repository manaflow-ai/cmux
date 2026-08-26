import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar mounted render diagnostic")
@MainActor
struct CustomSidebarRenderDiagnosticTests {
    private let diagnostic = CustomSidebarRenderDiagnostic(fileManagerProvider: { FileManager() })

    @Test("mounts the shared content view and writes a visible PNG")
    func writesVisibleArtifact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("smoke.swift")
        let outputURL = directory.appendingPathComponent("smoke.png")
        try "VStack { Text(\"Mounted smoke\"); Divider() }"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = try diagnostic.prepare(fileURL: sourceURL)
        let artifact = try diagnostic.render(
            plan: plan,
            width: 160,
            height: 90,
            outputURL: outputURL
        )

        #expect(artifact.width == 160)
        #expect(artifact.height == 90)
        #expect(artifact.visiblePixelCount > 0)
        #expect(artifact.byteCount > 8)
        #expect(try Data(contentsOf: outputURL).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("mounts a declarative JSON sidebar through the same content view")
    func writesJSONArtifact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("json-sidebar.json")
        let outputURL = directory.appendingPathComponent("json-sidebar.png")
        try #"{"version":1,"root":{"type":"text","text":"JSON smoke"}}"#
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = try diagnostic.prepare(fileURL: sourceURL)
        let artifact = try diagnostic.render(
            plan: plan,
            width: 160,
            height: 90,
            outputURL: outputURL
        )

        #expect(plan.kind == .json)
        #expect(artifact.visiblePixelCount > 0)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @Test("fails when the mounted tree produces no visible pixels")
    func rejectsBlankArtifact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("blank.swift")
        let outputURL = directory.appendingPathComponent("blank.png")
        try "Text(\"\")"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        let plan = try diagnostic.prepare(fileURL: sourceURL)
        do {
            _ = try diagnostic.render(
                plan: plan,
                width: 120,
                height: 80,
                outputURL: outputURL
            )
            Issue.record("Expected a blank mounted tree to fail")
        } catch let error as CustomSidebarRenderDiagnosticError {
            #expect(error == .blankOutput)
        }
    }

    @Test("preparation rejects an unsupported source")
    func rejectsUnsupportedSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("sidebar.txt")
        try "Text(\"not a sidebar\")"
            .write(to: sourceURL, atomically: true, encoding: .utf8)

        #expect(throws: CustomSidebarRenderDiagnosticError.unsupportedFile) {
            _ = try diagnostic.prepare(fileURL: sourceURL)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
