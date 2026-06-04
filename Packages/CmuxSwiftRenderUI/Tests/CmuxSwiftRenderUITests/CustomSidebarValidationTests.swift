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
        #expect(report.entries.first?.name == "missing")
        #expect(report.entries.first?.errorMessage == "Sidebar file is missing.")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
