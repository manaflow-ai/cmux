import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser REPL workspace binding")
struct BrowserReplWorkspaceBindingTests {
    private let known = UUID()
    private let focusedWorkspace = UUID()
    private let foreign = UUID()

    private func resolve(explicit: UUID? = nil, caller: UUID? = nil, focused: UUID?) -> Result<UUID, BrowserReplWorkspaceBinding.Failure> {
        let known = [self.known, focusedWorkspace]
        return BrowserReplWorkspaceBinding(
            exists: { known.contains($0) },
            focused: { focused }
        ).resolve(explicit: explicit, caller: caller)
    }

    @Test("The caller's workspace wins when this instance knows it")
    func callerWorkspaceKnown() {
        #expect(resolve(caller: known, focused: focusedWorkspace) == .success(known))
    }

    @Test("A caller workspace from another cmux instance falls back to the focused workspace")
    func callerWorkspaceUnknownFallsBack() {
        #expect(resolve(caller: foreign, focused: focusedWorkspace) == .success(focusedWorkspace))
    }

    @Test("A caller outside cmux binds to the focused workspace")
    func noCallerUsesFocused() {
        #expect(resolve(focused: focusedWorkspace) == .success(focusedWorkspace))
    }

    @Test("An explicit workspace must exist and never falls back")
    func explicitWorkspace() {
        #expect(resolve(explicit: known, caller: focusedWorkspace, focused: focusedWorkspace) == .success(known))
        #expect(resolve(explicit: foreign, focused: focusedWorkspace) == .failure(.explicitWorkspaceNotFound(foreign)))
    }

    @Test("Without a focused workspace the fallback fails")
    func noFocusedWorkspace() {
        #expect(resolve(caller: foreign, focused: nil) == .failure(.noFocusedWorkspace))
    }
}
