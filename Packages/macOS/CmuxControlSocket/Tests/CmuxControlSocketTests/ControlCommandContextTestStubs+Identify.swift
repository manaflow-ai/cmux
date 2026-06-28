import Foundation
@testable import CmuxControlSocket

// Benign defaults for the identify-domain seam, so a test fake that conforms to
// the full `ControlCommandContext` umbrella only has to implement the domain it
// actually exercises (same pattern as ControlCommandContextTestStubs.swift).

extension ControlIdentifyContext {
    func controlIdentifySocketPath() -> String { "" }
    func controlIdentifyFocused(params: [String: JSONValue]) -> ControlIdentifyFocusedSnapshot? { nil }
    func controlIdentifyCaller(
        params: [String: JSONValue],
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlIdentifyCallerSnapshot? { nil }
    func controlIdentifyBundle() -> ControlIdentifyBundleSnapshot {
        ControlIdentifyBundleSnapshot(
            bundleIdentifier: nil,
            bundlePath: "",
            executablePath: nil,
            cliPath: nil
        )
    }
}
