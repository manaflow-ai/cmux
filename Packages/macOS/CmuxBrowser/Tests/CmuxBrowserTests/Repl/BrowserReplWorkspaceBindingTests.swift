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

    /// An explicit selection the host cannot read as a workspace id (a
    /// ref a relay passed on unresolved, a blank value) is still explicit:
    /// it fails, never falls back to the caller's or the focused workspace.
    @Test("An explicit workspace that is not a workspace id fails and never falls back")
    func unreadableExplicitWorkspace() {
        let binding = BrowserReplWorkspaceBinding(exists: { [known] in $0 == known }, focused: { [focusedWorkspace] in focusedWorkspace })
        for handle in ["workspace:3", " ", ""] {
            #expect(binding.resolve(explicitHandle: handle, caller: known) == .failure(.explicitWorkspaceInvalid(handle)))
        }
        #expect(binding.resolve(explicitHandle: known.uuidString, caller: nil) == .success(known))
        #expect(binding.resolve(explicitHandle: nil, caller: known) == .success(known))
    }

    /// Owner decision 2026-10-06: a caller outside cmux (no workspace of
    /// this instance in its environment) gets one session per name, not
    /// the focused workspace's, so the binding tells it apart.
    @Test("A caller outside cmux, or one whose workspace this instance does not know, is told apart")
    func outsideCallerIsToldApart() {
        let binding = BrowserReplWorkspaceBinding(exists: { [known] in $0 == known }, focused: { [focusedWorkspace] in focusedWorkspace })
        #expect(binding.caller(explicitHandle: nil, caller: nil) == .success(.outside(focused: focusedWorkspace)))
        #expect(binding.caller(explicitHandle: nil, caller: foreign) == .success(.outside(focused: focusedWorkspace)))
        #expect(binding.caller(explicitHandle: nil, caller: known) == .success(.inside(known)))
        #expect(binding.caller(explicitHandle: known.uuidString, caller: nil) == .success(.inside(known)))
        let unfocused = BrowserReplWorkspaceBinding(exists: { _ in false }, focused: { nil })
        #expect(unfocused.caller(explicitHandle: nil, caller: nil) == .success(.outside(focused: nil)))
    }

    @Test("Without a focused workspace the fallback fails")
    func noFocusedWorkspace() {
        #expect(resolve(caller: foreign, focused: nil) == .failure(.noFocusedWorkspace))
    }
}
