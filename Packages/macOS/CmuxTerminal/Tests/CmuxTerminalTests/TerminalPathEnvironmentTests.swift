import Foundation
import CmuxTerminal
import Testing

@Suite("Terminal PATH environment")
struct TerminalPathEnvironmentTests {
    @Test("Drops malformed PATH components when prepending a cmux shim")
    func dropsMalformedPathComponentsWhenPrependingShim() {
        let shimDirectory = "/var/folders/demo/cmux-cli-shims/ABC"
        let malformedComponent = "\u{FFFD}u[\u{FFFD}\u{0008}`\u{FFFD}-\u{FFFD}(\u{FFFD}"
        let path = "/usr/bin:\(malformedComponent):/bin"

        let result = TerminalSurface.pathByPrependingUniqueDirectory(
            shimDirectory,
            to: path
        )

        #expect(result == "\(shimDirectory):/usr/bin:/bin")
    }

    @Test("Scopes shell history to the terminal surface")
    func scopesShellHistoryToSurface() {
        let surfaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let context = TerminalSurface.CmuxContextEnvironment(
            workspaceId: UUID(),
            surfaceId: surfaceID,
            terminalLifecycleId: UUID(),
            socketPath: "/tmp/cmux.sock"
        )
        var environment: [String: String] = [:]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedCmuxContextEnvironment(
            context,
            to: &environment,
            protectedKeys: &protectedKeys
        )

        #expect(environment["CMUX_HISTORY_FILE"] == TerminalSurface.terminalHistoryFileURL(surfaceID: surfaceID).path)
        #expect(protectedKeys.contains("CMUX_HISTORY_FILE"))
        #expect(TerminalSurface.terminalHistoryFileURL(surfaceID: surfaceID).lastPathComponent == "surface-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.history")
        #expect(TerminalSurface.terminalHistoryFileURL(surfaceID: surfaceID) != TerminalSurface.terminalHistoryFileURL(surfaceID: UUID()))
    }
}
