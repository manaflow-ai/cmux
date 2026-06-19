import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlCustomSidebarCommandHandler")
struct ControlCustomSidebarCommandHandlerTests {
    private let handler = ControlCustomSidebarCommandHandler()
    private let messages = ControlCustomSidebarCommandMessages(
        invalidName: "Sidebar name must not be empty.",
        selectMissingName: "Select requires a sidebar name."
    )

    @Test func validateRejectsExplicitEmptyName() throws {
        let directory = try temporaryDirectory()

        let result = handler.validate(
            params: ["name": .string(" \n ")],
            directory: directory,
            messages: messages
        )

        #expect(result == .err(
            code: "invalid_params",
            message: "Sidebar name must not be empty.",
            data: nil
        ))
    }

    @Test func reloadReportsAllNamesAndReloadedValidNames() throws {
        let directory = try temporaryDirectory()
        try writeValidJSONSidebar(named: "ok", in: directory)
        try #"{"root":{"type":"text","text":"Missing version"}}"#
            .write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        var reloadedNames: [String] = []

        let result = handler.reload(
            params: [:],
            directory: directory,
            messages: messages
        ) { names in
            reloadedNames = names
        }

        guard case .ok(.object(let payload)) = result else {
            Issue.record("Expected ok object payload")
            return
        }
        #expect(reloadedNames == ["broken", "ok"])
        #expect(payload["directory"] == .string(directory.path))
        #expect(payload["valid_count"] == .int(1))
        #expect(payload["error_count"] == .int(1))
        #expect(payload["reloaded_count"] == .int(1))
        #expect(payload["reloaded_names"] == .array([.string("ok")]))
    }

    @Test func selectMissingSidebarReturnsValidationMessageWithoutSelecting() throws {
        let directory = try temporaryDirectory()
        var selection: ControlCustomSidebarSelection?

        let result = handler.select(
            params: ["name": .string("missing")],
            directory: directory,
            providerIDPrefix: "cmux.sidebar.custom.",
            messages: messages
        ) { selection = $0 }

        guard case .ok(.object(let payload)) = result else {
            Issue.record("Expected ok object payload")
            return
        }
        #expect(selection == nil)
        #expect(payload["valid_count"] == .int(0))
        #expect(payload["error_count"] == .int(1))
        #expect(payload["message"] == .string("Sidebar file is missing."))
    }

    @Test func selectValidSidebarPersistsSelectionAndReportsProvider() throws {
        let directory = try temporaryDirectory()
        try writeValidJSONSidebar(named: "chosen", in: directory)
        var selection: ControlCustomSidebarSelection?

        let result = handler.select(
            params: ["name": .string(" chosen ")],
            directory: directory,
            providerIDPrefix: "cmux.sidebar.custom.",
            messages: messages
        ) { selection = $0 }

        guard case .ok(.object(let payload)) = result else {
            Issue.record("Expected ok object payload")
            return
        }
        #expect(selection == ControlCustomSidebarSelection(
            providerID: "cmux.sidebar.custom.chosen",
            name: "chosen"
        ))
        #expect(payload["selected_provider_id"] == .string("cmux.sidebar.custom.chosen"))
        #expect(payload["selected_name"] == .string("chosen"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-control-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeValidJSONSidebar(named name: String, in directory: URL) throws {
        try #"{"version":1,"root":{"type":"text","text":"OK"}}"#
            .write(to: directory.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
    }
}
