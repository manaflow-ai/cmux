import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Claude team task-list identity")
struct ClaudeTeamTaskListResolverTests {
    @Test("Resolves one exact agent membership to its canonical team task list")
    func resolvesExactAgentMembership() throws {
        let root = temporaryTeamsRoot(named: "exact")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "Shared_Team",
            leaderSessionID: "leader-session",
            leadAgentID: "agent-leader",
            memberIDs: ["agent-leader", "agent-teammate"],
            directoryName: "shared-team",
            in: root
        )
        let malformedDirectory = root.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: malformedDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"name":false}"#.utf8)
            .write(to: malformedDirectory.appendingPathComponent("config.json"))

        let resolution = try #require(
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate"
            )
        )
        let binding = resolution.binding

        #expect(binding.taskListID == "Shared_Team")
        #expect(binding.taskStoreIdentity == ClaudeTaskStoreIdentity(
            tasksRootURL: root.deletingLastPathComponent()
                .appendingPathComponent("tasks", isDirectory: true)
        ))
        #expect(binding.leaderSessionID == "leader-session")
        #expect(binding.agentIDs == ["agent-leader", "agent-teammate"])
    }

    @Test("Resolves the team leader without an agent id")
    func resolvesLeaderSession() throws {
        let root = temporaryTeamsRoot(named: "leader")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "Leader_Team",
            leaderSessionID: "leader-session",
            leadAgentID: "agent-leader",
            memberIDs: ["agent-leader", "agent-teammate"],
            directoryName: "leader-team",
            in: root
        )

        let resolution = try #require(
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "leader-session",
                agentID: nil
            )
        )

        #expect(resolution.binding.taskListID == "Leader_Team")
    }

    @Test("A binding without a leader session fails closed for session-only matches")
    func rejectsMissingSessionIdentity() throws {
        let binding = try #require(ClaudeTeamTaskListBinding(
            taskListID: "Agent_Only_Team",
            leaderSessionID: nil,
            agentIDs: ["agent-teammate"]
        ))

        #expect(!binding.matches(sessionID: "", agentID: nil))
        #expect(!binding.matches(sessionID: "unproven-session", agentID: nil))
        #expect(binding.matches(sessionID: "", agentID: "agent-teammate"))
    }

    @Test("Duplicate exact identities fail closed")
    func rejectsAmbiguousAgentMembership() throws {
        let root = temporaryTeamsRoot(named: "ambiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        for teamName in ["team-a", "team-b"] {
            try writeTeamConfig(
                name: teamName,
                leaderSessionID: "leader-\(teamName)",
                leadAgentID: nil,
                memberIDs: ["agent-shared"],
                directoryName: teamName,
                in: root
            )
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.ambiguousTeamMembership) {
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-shared"
            )
        }
    }

    @Test("Rejects a config whose canonical name does not own its directory")
    func rejectsMismatchedTeamDirectory() throws {
        let root = temporaryTeamsRoot(named: "mismatched-directory")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "expected-team",
            leaderSessionID: "leader-session",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "neighboring-team",
            in: root
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.invalidTeamDirectoryBinding) {
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate"
            )
        }
    }

    @Test("Reuses a proven shared binding after team metadata is removed")
    func reusesProvenBindingAfterTeamCleanup() throws {
        let root = temporaryTeamsRoot(named: "removed-team")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = try #require(ClaudeTeamTaskListBinding(
            taskListID: "Former_Team",
            leaderSessionID: "leader-session",
            agentIDs: ["agent-teammate"]
        ))

        let resolution = try ClaudeTeamTaskListResolver(teamsRootURL: root)
            .resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate",
                previouslyBoundBinding: previous
            )

        #expect(resolution?.binding == previous)
        #expect(resolution?.usesRetainedCleanupProof == true)
    }

    @Test("Reuses a proven shared binding when its config is already gone")
    func reusesProvenBindingAfterConfigCleanup() throws {
        let root = temporaryTeamsRoot(named: "partial-team-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("former-team", isDirectory: true),
            withIntermediateDirectories: true
        )
        let previous = try #require(ClaudeTeamTaskListBinding(
            taskListID: "Former_Team",
            leaderSessionID: "leader-session",
            agentIDs: ["agent-teammate"]
        ))

        let resolution = try ClaudeTeamTaskListResolver(teamsRootURL: root)
            .resolveTaskListBinding(
                sessionID: "leader-session",
                agentID: nil,
                previouslyBoundBinding: previous
            )

        #expect(resolution?.binding == previous)
        #expect(resolution?.usesRetainedCleanupProof == true)
    }

    @Test("An unrelated subagent cannot inherit a leader-session binding")
    func rejectsUnprovenAgentAfterTeamCleanup() throws {
        let root = temporaryTeamsRoot(named: "unproven-agent")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = try #require(ClaudeTeamTaskListBinding(
            taskListID: "Former_Team",
            leaderSessionID: "leader-session",
            agentIDs: ["agent-teammate"]
        ))

        let resolution = try ClaudeTeamTaskListResolver(teamsRootURL: root)
            .resolveTaskListBinding(
                sessionID: "leader-session",
                agentID: "ordinary-subagent",
                previouslyBoundBinding: previous
            )

        #expect(resolution == nil)
    }

    @Test("A proven binding remains current while team metadata is unchanged")
    func validatesProvenBindingAgainstUnchangedGeneration() throws {
        let root = temporaryTeamsRoot(named: "proven-fast-path")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "Shared_Team",
            leaderSessionID: "leader-session",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "shared-team",
            in: root
        )
        try writeTeamConfig(
            name: "Unrelated_Team",
            leaderSessionID: "unrelated-leader",
            leadAgentID: nil,
            memberIDs: ["unrelated-agent"],
            directoryName: "unrelated-team",
            in: root
        )
        let resolver = ClaudeTeamTaskListResolver(teamsRootURL: root)
        let previous = try #require(try resolver.resolveTaskListBinding(
            sessionID: "teammate-session",
            agentID: "agent-teammate"
        )).binding

        let resolution = try resolver.resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate",
                previouslyBoundBinding: previous
            )

        #expect(resolution?.binding.taskListID == "Shared_Team")
        #expect(resolution?.usesRetainedCleanupProof == false)
    }

    @Test("A new competing team invalidates the proven fast path")
    func rejectsCompetingIdentityAddedAfterBinding() throws {
        let root = temporaryTeamsRoot(named: "new-ambiguity")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "First_Team",
            leaderSessionID: "leader-session",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "first-team",
            in: root
        )
        let resolver = ClaudeTeamTaskListResolver(teamsRootURL: root)
        let previous = try #require(try resolver.resolveTaskListBinding(
            sessionID: "teammate-session",
            agentID: "agent-teammate"
        )).binding
        try writeTeamConfig(
            name: "Second_Team",
            leaderSessionID: "second-leader",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "second-team",
            in: root
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.ambiguousTeamMembership) {
            try resolver.resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate",
                previouslyBoundBinding: previous
            )
        }
    }

    @Test("An in-place competing config edit invalidates a proven binding")
    func rejectsCompetingIdentityEditedAfterBinding() throws {
        let root = temporaryTeamsRoot(named: "edited-ambiguity")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "First_Team",
            leaderSessionID: "leader-session",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "first-team",
            in: root
        )
        try writeTeamConfig(
            name: "Second_Team",
            leaderSessionID: "second-leader",
            leadAgentID: nil,
            memberIDs: ["unrelated-agent"],
            directoryName: "second-team",
            in: root
        )
        let resolver = ClaudeTeamTaskListResolver(teamsRootURL: root)
        let previous = try #require(try resolver.resolveTaskListBinding(
            sessionID: "teammate-session",
            agentID: "agent-teammate"
        )).binding

        try writeTeamConfig(
            name: "Second_Team",
            leaderSessionID: "second-leader",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "second-team",
            in: root
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.ambiguousTeamMembership) {
            try resolver.resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate",
                previouslyBoundBinding: previous
            )
        }
    }

    @Test("Changed membership falls through to the bounded team scan")
    func resolvesNewTeamAfterMembershipChanges() throws {
        let root = temporaryTeamsRoot(named: "changed-membership")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "Former_Team",
            leaderSessionID: "former-leader",
            leadAgentID: nil,
            memberIDs: ["different-agent"],
            directoryName: "former-team",
            in: root
        )
        try writeTeamConfig(
            name: "Current_Team",
            leaderSessionID: "current-leader",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "current-team",
            in: root
        )
        let previous = try #require(ClaudeTeamTaskListBinding(
            taskListID: "Former_Team",
            leaderSessionID: "former-leader",
            agentIDs: ["agent-teammate"]
        ))

        let resolution = try ClaudeTeamTaskListResolver(teamsRootURL: root)
            .resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate",
                previouslyBoundBinding: previous
            )

        #expect(resolution?.binding.taskListID == "Current_Team")
    }

    @Test("Rejects a team root beyond the entry boundary")
    func rejectsTeamRootBeyondEntryBoundary() throws {
        let root = temporaryTeamsRoot(named: "entry-overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0...ClaudeTeamTaskListResolver.maximumTeamRootEntryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.tooManyTeamRootEntries(
            limit: ClaudeTeamTaskListResolver.maximumTeamRootEntryCount
        )) {
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate"
            )
        }
    }

    @Test("Rejects a team config beyond the byte boundary")
    func rejectsOversizedTeamConfig() throws {
        let root = temporaryTeamsRoot(named: "oversized")
        defer { try? FileManager.default.removeItem(at: root) }
        let teamDirectory = root.appendingPathComponent("large-team", isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectory, withIntermediateDirectories: true)
        let configURL = teamDirectory.appendingPathComponent("config.json")
        try Data(
            repeating: 0x20,
            count: ClaudeTeamTaskListResolver.maximumTeamConfigFileByteCount + 1
        ).write(to: configURL)

        #expect(throws: ClaudeTaskSnapshotLoaderError.teamConfigFileTooLarge(
            fileName: "config.json",
            limit: ClaudeTeamTaskListResolver.maximumTeamConfigFileByteCount
        )) {
            try ClaudeTeamTaskListResolver(teamsRootURL: root).resolveTaskListBinding(
                sessionID: "teammate-session",
                agentID: "agent-teammate"
            )
        }
    }

    @Test("Automatic-team scans honor an injected monotonic deadline")
    func rejectsExpiredOperationDeadline() {
        let resolver = ClaudeTeamTaskListResolver(
            teamsRootURL: URL(fileURLWithPath: "/unused", isDirectory: true),
            deadlineUptime: 10,
            uptime: { 10 }
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.operationDeadlineExceeded) {
            try resolver.resolveTaskListBinding(
                sessionID: "session",
                agentID: nil
            )
        }
    }

    @Test("Current binding lookup fails closed when team metadata changes")
    func rejectsUnstableCurrentBinding() throws {
        let root = temporaryTeamsRoot(named: "current-binding-race")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTeamConfig(
            name: "Racing_Team",
            leaderSessionID: "leader-session",
            leadAgentID: nil,
            memberIDs: ["agent-teammate"],
            directoryName: "racing-team",
            in: root
        )
        let marker = root.appendingPathComponent("scan-mutated", isDirectory: true)
        let fileManager = MutatingTeamScanFileManager {
            try? FileManager.default.createDirectory(
                at: marker,
                withIntermediateDirectories: false
            )
        }
        let resolver = ClaudeTeamTaskListResolver(
            teamsRootURL: root,
            fileManager: fileManager
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.teamConfigurationChangedDuringScan) {
            try resolver.currentTaskListBinding(forTaskListID: "Racing_Team")
        }
    }

    private func temporaryTeamsRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-claude-teams-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func writeTeamConfig(
        name: String,
        leaderSessionID: String?,
        leadAgentID: String?,
        memberIDs: [String],
        directoryName: String,
        in root: URL
    ) throws {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var value: [String: Any] = [
            "name": name,
            "members": memberIDs.map { ["agentId": $0] },
        ]
        if let leaderSessionID { value["leadSessionId"] = leaderSessionID }
        if let leadAgentID { value["leadAgentId"] = leadAgentID }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("config.json"))
    }
}

private final class MutatingTeamScanFileManager: FileManager {
    private let mutation: () -> Void
    private var didMutate = false

    init(mutation: @escaping () -> Void) {
        self.mutation = mutation
        super.init()
    }

    override func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        errorHandler handler: ((URL, Error) -> Bool)? = nil
    ) -> FileManager.DirectoryEnumerator? {
        let enumerator = super.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask,
            errorHandler: handler
        )
        if !didMutate {
            didMutate = true
            mutation()
        }
        return enumerator
    }
}
