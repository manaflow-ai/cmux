import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar validation")
struct CustomSidebarValidationTests {
    private let validator = CustomSidebarValidator()

    @Test("discovers one file per sidebar name and prefers Swift")
    func discoversSwiftBeforeJSON() throws {
        let directory = try temporaryDirectory()
        try """
        Text("Swift")
        """.write(to: directory.appendingPathComponent("finder.swift"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"root":{"type":"text","text":"JSON"}}
        """.write(to: directory.appendingPathComponent("finder.json"), atomically: true, encoding: .utf8)

        let urls = validator.discover(in: directory)

        #expect(urls.map(\.lastPathComponent) == ["finder.swift"])
    }

    @Test("reports JSON schema errors with root path")
    func reportsMissingJSONVersion() throws {
        let directory = try temporaryDirectory()
        try """
        {"root":{"type":"text","text":"Missing version"}}
        """.write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "Missing key 'version' at root")
    }

    @Test("reports Swift files that do not render a supported view")
    func reportsSwiftWithoutRenderableView() throws {
        let directory = try temporaryDirectory()
        try """
        let answer = 42
        """.write(to: directory.appendingPathComponent("broken.swift"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "No supported SwiftUI view found.")
    }

    @Test("reports a missing requested sidebar name")
    func reportsMissingRequestedName() throws {
        let directory = try temporaryDirectory()

        let report = validator.validate(directory: directory, name: "missing")

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.names == ["missing"])
        #expect(report.entries.first?.name == "missing")
        #expect(report.entries.first?.errorMessage == "Sidebar file is missing.")
    }

    @MainActor
    @Test("model re-resolves preferred file kind on reload")
    func modelReresolvesPreferredFileKind() throws {
        let directory = try temporaryDirectory()
        let jsonURL = directory.appendingPathComponent("finder.json")
        let swiftURL = directory.appendingPathComponent("finder.swift")

        try """
        {"version":1,"root":{"type":"text","text":"JSON"}}
        """.write(to: jsonURL, atomically: true, encoding: .utf8)

        let model = CustomSidebarModel(fileURL: jsonURL)
        model.reload()
        guard case .json = model.state else {
            Issue.record("Expected JSON sidebar state before Swift file exists")
            return
        }

        try """
        Text("Swift")
        """.write(to: swiftURL, atomically: true, encoding: .utf8)

        model.reload()
        guard case let .swiftSource(source) = model.state else {
            Issue.record("Expected Swift sidebar state after Swift file is added")
            return
        }
        #expect(source.contains("Text(\"Swift\")"))

        try FileManager.default.removeItem(at: swiftURL)

        model.reload()
        guard case .json = model.state else {
            Issue.record("Expected JSON sidebar state after Swift file is removed")
            return
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
