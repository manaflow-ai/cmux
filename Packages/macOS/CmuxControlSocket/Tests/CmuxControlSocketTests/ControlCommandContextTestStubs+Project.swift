import Foundation
@testable import CmuxControlSocket

// Benign defaults for the project-domain seam, so a test fake that conforms to
// the full `ControlCommandContext` umbrella only has to implement the domain
// it actually exercises (same pattern as ControlCommandContextTestStubs.swift;
// kept in its own file because that shared file is owned by another stage-3c
// agent).

extension ControlProjectContext {
    func controlProjectRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { false }
    func controlProjectOpen(
        routing: ControlRoutingSelectors,
        path: String,
        requestedFocus: Bool
    ) -> ControlProjectOpenResolution { .workspaceNotFound }
    func controlProjectSetTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        tabRaw: String?
    ) -> ControlProjectSetTabResolution { .panelNotFound }
    func controlProjectSetScheme(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution { .panelNotFound }
    func controlProjectSetConfiguration(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution { .panelNotFound }
    func controlProjectSetSelectedTarget(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectTargetResolution { .panelNotFound }
    func controlProjectSetSelectedFile(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        path: String?
    ) -> ControlProjectUpdateResolution { .panelNotFound }
    func controlProjectSetSettingsFilter(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        text: String
    ) -> ControlProjectUpdateResolution { .panelNotFound }
    func controlProjectGetState(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlProjectStateResolution { .panelNotFound }
    func controlMarkdownOpen(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        filePath: String,
        directionRaw: String,
        fontSize: Double?,
        fontSizeInvalid: Bool,
        requestedFocus: Bool
    ) -> ControlMarkdownOpenResolution { .workspaceNotFound }
    func controlFileOpen(params: [String: JSONValue]) -> ControlCallResult {
        .err(code: "unavailable", message: "", data: nil)
    }
}
