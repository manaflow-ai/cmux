import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlCustomSidebarCommandHandler")
struct ControlCustomSidebarCommandHandlerTests {
    private let handler = ControlCustomSidebarCommandHandler(validator: TestCustomSidebarValidator())
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

    @Test func reloadReportsValidNamesAndReloadsAllReportNames() throws {
        let directory = try temporaryDirectory()
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
}

private struct TestCustomSidebarValidator: ControlCustomSidebarValidating {
    func validate(directory: URL, name requestedName: String?) -> ControlCustomSidebarValidationReport {
        let entries: [ControlCustomSidebarValidationEntry]
        switch requestedName {
        case .some("chosen"):
            entries = [entry(name: "chosen", directory: directory, isValid: true)]
        case .some("missing"):
            entries = [entry(
                name: "missing",
                directory: directory,
                isValid: false,
                errorMessage: "Sidebar file is missing."
            )]
        case .some(let name):
            entries = [entry(
                name: name,
                directory: directory,
                isValid: false,
                errorMessage: "Sidebar file is missing."
            )]
        case .none:
            entries = [
                entry(name: "broken", directory: directory, isValid: false, errorMessage: "Missing version"),
                entry(name: "ok", directory: directory, isValid: true),
            ]
        }
        return ControlCustomSidebarValidationReport(entries: entries)
    }

    private func entry(
        name: String,
        directory: URL,
        isValid: Bool,
        errorMessage: String? = nil
    ) -> ControlCustomSidebarValidationEntry {
        ControlCustomSidebarValidationEntry(
            name: name,
            path: directory.appendingPathComponent("\(name).json").path,
            kind: "json",
            isValid: isValid,
            errorMessage: errorMessage
        )
    }
}
