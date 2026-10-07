import Foundation
import Testing
@testable import CmuxBrowser

/// A caller's workspace comes from the socket peer's process tree, which the
/// caller cannot choose, and that workspace is authoritative: a caller in
/// workspace A's terminal cannot list, reset or evaluate in workspace B's
/// named sessions through `all_workspaces`, `workspace_id` or
/// `CMUX_WORKSPACE_ID`.
@Suite("Browser REPL caller locality")
struct BrowserReplCallerLocalityTests {
    private let workspaceA = UUID()
    private let workspaceB = UUID()
    private let host: Int32 = 500

    /// launchd(1) -> cmux(500) -> shell in A's pane (600) -> cmux CLI (601);
    /// a process A's shell started in a new session (602, no controlling
    /// terminal) -> its child (603); a process outside cmux (700, a child
    /// of launchd) and a shell in B's pane (800).
    private var locality: BrowserReplCallerLocality {
        let parents: [Int32: Int32] = [500: 1, 600: 500, 601: 600, 602: 600, 603: 602, 700: 1, 800: 500]
        let terminals: [Int32: UUID] = [600: workspaceA, 601: workspaceA, 800: workspaceB]
        return BrowserReplCallerLocality(host: host, parent: { parents[$0] }, workspace: { terminals[$0] })
    }

    private var binding: BrowserReplWorkspaceBinding {
        let known = [workspaceA, workspaceB]
        return BrowserReplWorkspaceBinding(exists: { known.contains($0) }, focused: { [workspaceB] in workspaceB })
    }

    @Test("A peer in a cmux terminal resolves to that terminal's workspace")
    func peerInTerminal() {
        #expect(locality.workspace(ofPeer: 601) == workspaceA)
        #expect(locality.workspace(ofPeer: 800) == workspaceB)
    }

    @Test("A peer without a controlling terminal resolves through its ancestry")
    func peerThroughAncestry() {
        #expect(locality.workspace(ofPeer: 603) == workspaceA)
    }

    @Test("A peer outside every cmux terminal, cmux itself, or no peer resolves to none")
    func peerOutside() {
        #expect(locality.workspace(ofPeer: 700) == nil)
        #expect(locality.workspace(ofPeer: host) == nil)
        #expect(locality.workspace(ofPeer: nil) == nil)
        #expect(locality.workspace(ofPeer: 999) == nil)
    }

    @Test("A parent loop ends the walk")
    func parentLoop() {
        let looping = BrowserReplCallerLocality(host: host, parent: { $0 == 10 ? 11 : 10 }, workspace: { _ in nil })
        #expect(looping.workspace(ofPeer: 10) == nil)
    }

    @Test("A caller in workspace A's terminal cannot list or reset every workspace's sessions")
    func allWorkspacesRefused() {
        let derived = locality.workspace(ofPeer: 601)
        #expect(
            binding.scope(allWorkspaces: true, explicitHandle: nil, caller: nil, derived: derived)
                == .failure(.allWorkspacesDenied(caller: workspaceA))
        )
    }

    @Test("A caller in workspace A's terminal cannot name workspace B")
    func otherWorkspaceRefused() {
        let derived = locality.workspace(ofPeer: 601)
        // eval with workspace_id B on a named session
        #expect(
            binding.caller(explicitHandle: workspaceB.uuidString, caller: nil, derived: derived)
                == .failure(.otherWorkspaceDenied(requested: workspaceB, caller: workspaceA))
        )
        // reset and list with workspace_id B
        #expect(
            binding.scope(allWorkspaces: false, explicitHandle: workspaceB.uuidString, caller: nil, derived: derived)
                == .failure(.otherWorkspaceDenied(requested: workspaceB, caller: workspaceA))
        )
        // Naming its own workspace is fine.
        #expect(binding.caller(explicitHandle: workspaceA.uuidString, caller: nil, derived: derived) == .success(.inside(workspaceA)))
    }

    @Test("A caller in workspace A's terminal that claims workspace B in its environment stays in A")
    func environmentClaimIgnored() {
        let derived = locality.workspace(ofPeer: 601)
        #expect(binding.caller(explicitHandle: nil, caller: workspaceB, derived: derived) == .success(.inside(workspaceA)))
        #expect(
            binding.scope(allWorkspaces: false, explicitHandle: nil, caller: workspaceB, derived: derived)
                == .success(.caller(.inside(workspaceA)))
        )
    }

    @Test("A caller outside every cmux terminal keeps the outside-caller behavior")
    func outsideCallerUnchanged() {
        let derived = locality.workspace(ofPeer: 700)
        #expect(binding.scope(allWorkspaces: true, explicitHandle: nil, caller: nil, derived: derived) == .success(.allWorkspaces))
        #expect(binding.caller(explicitHandle: workspaceA.uuidString, caller: nil, derived: derived) == .success(.inside(workspaceA)))
        #expect(binding.caller(explicitHandle: nil, caller: workspaceA, derived: derived) == .success(.inside(workspaceA)))
        #expect(binding.caller(explicitHandle: nil, caller: nil, derived: derived) == .success(.outside(focused: workspaceB)))
    }
}
