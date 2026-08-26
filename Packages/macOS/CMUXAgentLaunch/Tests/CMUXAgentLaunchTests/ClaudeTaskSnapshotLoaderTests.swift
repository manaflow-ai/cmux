import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Claude task snapshots")
struct ClaudeTaskSnapshotLoaderTests {
    @Test("Loads a complete session snapshot and omits deleted tasks")
    func loadsCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-tasks-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("session-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeTask(
            #"{"id":"10","subject":"Ship the fix","activeForm":"Shipping the fix","status":"in_progress"}"#,
            named: "10.json",
            in: sessionDirectory
        )
        try writeTask(
            #"{"id":"2","subject":"Write the test","activeForm":"Writing the test","status":"completed"}"#,
            named: "2.json",
            in: sessionDirectory
        )
        try writeTask(
            #"{"id":"3","subject":"Old task","activeForm":"Deleting the old task","status":"deleted"}"#,
            named: "3.json",
            in: sessionDirectory
        )
        try writeTask(#"{"broken":true}"#, named: "malformed.json", in: sessionDirectory)

        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)
        let snapshot = try #require(try loader.load(sessionID: "abc"))
        let todos = snapshot.todos

        #expect(snapshot.directoryName == "session-abc")
        #expect(todos.map(\.id) == ["2", "10"])
        #expect(todos.map(\.content) == ["Write the test", "Ship the fix"])
        #expect(todos.map(\.activeForm) == ["Writing the test", "Shipping the fix"])
        #expect(todos.map(\.state) == [.completed, .inProgress])
        #expect(todos.map(\.displayContent) == ["Write the test", "Shipping the fix"])
    }

    @Test("Ignores a task record whose filename does not match its identity")
    func ignoresMismatchedTaskFilename() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-task-id-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("identity", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"2","subject":"Mismatched task","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "identity")
        )

        #expect(snapshot.todos.isEmpty)
    }

    @Test("Supports the unprefixed session directory layout")
    func supportsUnprefixedSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-tasks-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root.appendingPathComponent("abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTask(
            #"{"id":"1","subject":"First task","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "abc")
        )

        #expect(snapshot.directoryName == "abc")
        #expect(snapshot.todos.map(\.content) == ["First task"])
    }

    @Test("A deterministic session directory wins over duplicate neighboring identities")
    func prefersDeterministicSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-direct-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("plain-session", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        for directory in [sessionDirectory, neighboringDirectory] {
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "plain-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Shared task")
        ))

        #expect(snapshot.directoryName == "plain-session")
    }

    @Test("A mismatched deterministic session directory does not fall through")
    func rejectsNeighborAfterDeterministicIdentityMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-direct-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("plain-session", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("session-team", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Partially written","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Expected task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )

        let snapshot = try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "plain-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Expected task")
        )

        #expect(snapshot == nil)
    }

    @Test("Direct session loading never scans neighboring task directories")
    func directSessionLoadingDoesNotScanNeighbors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-direct-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let neighboringDirectory = root.appendingPathComponent("shared-team", isDirectory: true)
        try FileManager.default.createDirectory(
            at: neighboringDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Shared task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)
        let identity = ClaudeTaskIdentity(id: "1", subject: "Shared task")

        #expect(try loader.loadDirectSessionTaskList(
            sessionID: "personal-session",
            taskIdentity: identity
        ) == nil)
        let fallbackSnapshot = try #require(try loader.load(
            sessionID: "personal-session",
            taskIdentity: identity
        ))
        #expect(fallbackSnapshot.directoryName == "shared-team")
    }

    @Test("A proven binding never falls through to a neighboring identity match")
    func boundTaskListDoesNotScanNeighbors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-bound-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boundDirectory = root.appendingPathComponent("former-team", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("neighbor-team", isDirectory: true)
        try FileManager.default.createDirectory(at: boundDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Former task","status":"pending"}"#,
            named: "1.json",
            in: boundDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Current task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)
        let identity = ClaudeTaskIdentity(id: "1", subject: "Current task")

        #expect(try loader.loadBoundTaskList(
            directoryName: "former-team",
            taskIdentity: identity
        ) == nil)
        let compatibilitySnapshot = try #require(try loader.load(
            sessionID: "unrelated-session",
            taskIdentity: identity
        ))
        #expect(compatibilitySnapshot.directoryName == "neighbor-team")
    }

    @Test("Resolves an unrelated team directory by one exact task identity")
    func resolvesUniqueTeamDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-team-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDirectory = root.appendingPathComponent("session-team-a", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("session-team-b", isDirectory: true)
        try FileManager.default.createDirectory(at: matchingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Team task","status":"pending"}"#,
            named: "1.json",
            in: matchingDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Neighbor task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "unrelated-hook-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Team task")
        ))

        #expect(snapshot.directoryName == "session-team-a")
        #expect(snapshot.todos.map(\.content) == ["Team task"])
    }

    @Test("Identity scans ignore oversized fields in nonmatching neighboring tasks")
    func ignoresOversizedTextInNonmatchingNeighbors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-bounded-neighbors-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let matchingDirectory = root.appendingPathComponent("matching-team", isDirectory: true)
        let subjectOverflowDirectory = root.appendingPathComponent(
            "subject-overflow-team",
            isDirectory: true
        )
        let activeFormOverflowDirectory = root.appendingPathComponent(
            "active-form-overflow-team",
            isDirectory: true
        )
        for directory in [
            matchingDirectory,
            subjectOverflowDirectory,
            activeFormOverflowDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeTask(
            #"{"id":"1","subject":"Exact task","status":"pending"}"#,
            named: "1.json",
            in: matchingDirectory
        )
        let oversizedSubject = String(
            repeating: "s",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount + 1
        )
        try writeTask(
            #"{"id":"1","subject":"\#(oversizedSubject)","status":"pending"}"#,
            named: "1.json",
            in: subjectOverflowDirectory
        )
        let oversizedActiveForm = String(
            repeating: "a",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount + 1
        )
        try writeTask(
            #"{"id":"1","subject":"Different task","activeForm":"\#(oversizedActiveForm)","status":"in_progress"}"#,
            named: "1.json",
            in: activeFormOverflowDirectory
        )

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "unrelated-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Exact task")
        ))

        #expect(snapshot.directoryName == "matching-team")
        #expect(snapshot.todos.map(\.content) == ["Exact task"])
    }

    @Test("Configured task-list identifiers resolve one canonical direct child")
    func resolvesConfiguredTaskListDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-configured-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuredDirectory = root.appendingPathComponent("shared-task-list", isDirectory: true)
        let unicodeDirectory = root.appendingPathComponent("shared----list", isDirectory: true)
        let neighboringDirectory = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unicodeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighboringDirectory, withIntermediateDirectories: true)
        try writeTask(
            #"{"id":"1","subject":"Configured task","status":"pending"}"#,
            named: "1.json",
            in: configuredDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"UTF-16 task","status":"pending"}"#,
            named: "1.json",
            in: unicodeDirectory
        )
        try writeTask(
            #"{"id":"1","subject":"Neighbor task","status":"pending"}"#,
            named: "1.json",
            in: neighboringDirectory
        )
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)

        let snapshot = try #require(
            try loader.loadConfiguredTaskList(taskListID: "shared/task list")
        )

        #expect(snapshot.directoryName == "shared-task-list")
        #expect(snapshot.todos.map(\.content) == ["Configured task"])
        let unicodeSnapshot = try #require(
            try loader.loadConfiguredTaskList(taskListID: "shared/🌈 list")
        )
        #expect(unicodeSnapshot.directoryName == "shared----list")
        #expect(unicodeSnapshot.todos.map(\.content) == ["UTF-16 task"])
        #expect(try loader.loadConfiguredTaskList(taskListID: "missing/list") == nil)
        let cleanedUpSnapshot = try #require(
            try loader.loadKnownTaskList(taskListID: "missing/list")
        )
        #expect(cleanedUpSnapshot.directoryName == "missing-list")
        #expect(cleanedUpSnapshot.todos.isEmpty)
    }

    @Test("A known task-list path must remain a direct non-symlink directory")
    func rejectsInvalidKnownTaskListPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-known-task-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let knownPath = root.appendingPathComponent("shared-list", isDirectory: true)
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)

        try Data().write(to: knownPath)
        #expect(throws: ClaudeTaskSnapshotLoaderError.invalidTaskDirectory(
            directoryName: "shared-list"
        )) {
            try loader.loadKnownTaskList(taskListID: "shared/list")
        }

        try FileManager.default.removeItem(at: knownPath)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: knownPath, withDestinationURL: target)
        #expect(throws: ClaudeTaskSnapshotLoaderError.invalidTaskDirectory(
            directoryName: "shared-list"
        )) {
            try loader.loadKnownTaskList(taskListID: "shared/list")
        }
    }

    @Test("A known task list disappearing before enumeration becomes empty")
    func treatsKnownTaskListDeletionRaceAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-known-task-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knownDirectory = root.appendingPathComponent("shared-list", isDirectory: true)
        try FileManager.default.createDirectory(
            at: knownDirectory,
            withIntermediateDirectories: true
        )
        let fileManager = DisappearingTaskDirectoryFileManager(
            disappearingDirectoryURL: knownDirectory
        )

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(
            tasksRootURL: root,
            fileManager: fileManager
        ).loadKnownTaskList(taskListID: "shared/list"))

        #expect(snapshot.directoryName == "shared-list")
        #expect(snapshot.todos.isEmpty)
    }

    @Test("A known task list disappearing after enumeration becomes empty")
    func treatsPostEnumerationTaskListDeletionAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-known-task-post-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knownDirectory = root.appendingPathComponent("shared-list", isDirectory: true)
        try FileManager.default.createDirectory(
            at: knownDirectory,
            withIntermediateDirectories: true
        )
        try writeTask(
            #"{"id":"1","subject":"Must not survive deletion","status":"pending"}"#,
            named: "1.json",
            in: knownDirectory
        )
        let fileManager = DisappearingTaskDirectoryFileManager(
            disappearingDirectoryURL: knownDirectory,
            deletesAfterEnumeration: true
        )

        let snapshot = try #require(try ClaudeTaskSnapshotLoader(
            tasksRootURL: root,
            fileManager: fileManager
        ).loadKnownTaskList(taskListID: "shared/list"))

        #expect(snapshot.directoryName == "shared-list")
        #expect(snapshot.todos.isEmpty)
    }

    @Test("Task snapshot reads honor an injected monotonic deadline")
    func rejectsExpiredOperationDeadline() {
        let loader = ClaudeTaskSnapshotLoader(
            tasksRootURL: URL(fileURLWithPath: "/unused", isDirectory: true),
            deadlineUptime: 10,
            uptime: { 10 }
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.operationDeadlineExceeded) {
            try loader.loadKnownTaskList(taskListID: "shared-list")
        }
    }

    @Test("Rejects an ambiguous team-directory identity")
    func rejectsAmbiguousTeamDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-ambiguous-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["session-team-a", "session-team-b"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeTask(
                #"{"id":"1","subject":"Shared task","status":"pending"}"#,
                named: "1.json",
                in: directory
            )
        }

        let snapshot = try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
            sessionID: "unrelated-hook-session",
            taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Shared task")
        )

        #expect(snapshot == nil)
    }

    @Test("A bound empty directory remains an authoritative snapshot")
    func distinguishesBoundEmptyDirectoryFromUnresolved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-empty-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boundDirectory = root.appendingPathComponent("session-team-a", isDirectory: true)
        try FileManager.default.createDirectory(at: boundDirectory, withIntermediateDirectories: true)
        let loader = ClaudeTaskSnapshotLoader(tasksRootURL: root)

        let emptySnapshot = try #require(try loader.load(
            sessionID: "unrelated-hook-session",
            boundDirectoryName: "session-team-a"
        ))

        #expect(emptySnapshot.directoryName == "session-team-a")
        #expect(emptySnapshot.todos.isEmpty)
        #expect(try loader.load(sessionID: "unrelated-hook-session") == nil)
    }

    @Test("Resolves the task root from Claude's configured directory")
    func resolvesConfiguredTaskRoot() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(ClaudeTaskRootResolver(
            environment: ["HOME": "/tmp/hook-home"],
            homeDirectoryURL: home
        ).resolve().path == URL(
            fileURLWithPath: "/tmp/hook-home/.claude/tasks",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(ClaudeTaskRootResolver(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-profile",
            ],
            homeDirectoryURL: home
        ).resolve().path == URL(
            fileURLWithPath: "/tmp/claude-profile/tasks",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(ClaudeTaskRootResolver(
            environment: [
                "HOME": "/tmp/hook-home",
                "CLAUDE_CONFIG_DIR": "~/claude-profile",
            ],
            homeDirectoryURL: home
        ).resolve().path == URL(
            fileURLWithPath: "/tmp/hook-home/claude-profile/tasks",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(ClaudeTaskRootResolver(
            environment: ["HOME": "  "],
            homeDirectoryURL: home
        ).resolve().path == URL(
            fileURLWithPath: "/Users/example/.claude/tasks",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test("Canonical task-root aliases share filesystem access and identity")
    func canonicalizesTaskRootAliases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-task-root-alias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realConfigRoot = root.appendingPathComponent("real-profile", isDirectory: true)
        let aliasedConfigRoot = root.appendingPathComponent("linked-profile", isDirectory: true)
        let realTasksRoot = realConfigRoot.appendingPathComponent("tasks", isDirectory: true)
        let taskDirectory = realTasksRoot.appendingPathComponent("shared-list", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasedConfigRoot,
            withDestinationURL: realConfigRoot
        )
        try writeTask(
            #"{"id":"1","subject":"Canonical task","status":"pending"}"#,
            named: "1.json",
            in: taskDirectory
        )
        let aliasedTasksRoot = aliasedConfigRoot.appendingPathComponent("tasks", isDirectory: true)
        let realLoader = ClaudeTaskSnapshotLoader(tasksRootURL: realTasksRoot)
        let aliasedLoader = ClaudeTaskSnapshotLoader(tasksRootURL: aliasedTasksRoot)

        #expect(aliasedLoader.tasksRootURL == realLoader.tasksRootURL)
        #expect(
            ClaudeTaskStoreIdentity(tasksRootURL: aliasedTasksRoot)
                == ClaudeTaskStoreIdentity(tasksRootURL: realTasksRoot)
        )
        let snapshot = try #require(
            try aliasedLoader.loadKnownTaskList(taskListID: "shared/list")
        )
        #expect(snapshot.todos.map(\.content) == ["Canonical task"])
    }

    @Test("Task-store identity namespaces matching paths by relay host")
    func namespacesTaskStoreIdentityByRelayHost() {
        let tasksRoot = URL(
            fileURLWithPath: "/home/agent/.claude/tasks",
            isDirectory: true
        )
        let firstHost = ClaudeTaskStoreIdentity(
            tasksRootURL: tasksRoot,
            hostNamespace: "relay:127.0.0.1:41001"
        )
        let secondHost = ClaudeTaskStoreIdentity(
            tasksRootURL: tasksRoot,
            hostNamespace: "relay:127.0.0.1:41002"
        )

        #expect(firstHost != secondHost)
        #expect(
            ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
                == ClaudeTaskStoreIdentity(tasksRootURL: tasksRoot)
        )
    }

    @Test("A tasks-leaf symlink does not relocate the logical teams sibling")
    func resolvesTaskAndTeamRootsIndependently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-independent-roots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileRoot = root.appendingPathComponent("profile", isDirectory: true)
        let externalTasksRoot = root.appendingPathComponent("external-tasks", isDirectory: true)
        let logicalTasksRoot = profileRoot.appendingPathComponent("tasks", isDirectory: true)
        let logicalTeamsRoot = profileRoot.appendingPathComponent("teams", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalTasksRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logicalTeamsRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: logicalTasksRoot,
            withDestinationURL: externalTasksRoot
        )
        let resolver = ClaudeTaskRootResolver(
            environment: ["CLAUDE_CONFIG_DIR": profileRoot.path],
            homeDirectoryURL: root
        )

        #expect(resolver.resolve() == externalTasksRoot.canonicalClaudeTaskStoreDirectoryURL)
        #expect(resolver.resolveTeamsRoot() == logicalTeamsRoot.canonicalClaudeTaskStoreDirectoryURL)
    }

    @Test("Task snapshots reject an oversized subject")
    func rejectsOversizedSubject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-subject-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("subject-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let subject = String(
            repeating: "x",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount + 1
        )
        try writeTask(
            #"{"id":"1","subject":"\#(subject)","status":"pending"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.taskTextTooLarge(
            fileName: "1.json",
            field: "subject",
            limit: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "subject-overflow")
        }
    }

    @Test("Task snapshots reject an oversized active form")
    func rejectsOversizedActiveForm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-active-form-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("active-form-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let activeForm = String(
            repeating: "x",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount + 1
        )
        try writeTask(
            #"{"id":"1","subject":"Task","activeForm":"\#(activeForm)","status":"in_progress"}"#,
            named: "1.json",
            in: sessionDirectory
        )

        #expect(throws: ClaudeTaskSnapshotLoaderError.taskTextTooLarge(
            fileName: "1.json",
            field: "activeForm",
            limit: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "active-form-overflow")
        }
    }

    @Test("Task snapshots reject aggregate text beyond the snapshot byte boundary")
    func rejectsAggregateTaskTextOverflow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-text-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("text-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let subject = String(
            repeating: "x",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount
        )
        let taskCount = ClaudeTaskSnapshotLoader.maximumSnapshotTextByteCount
            / ClaudeTaskSnapshotLoader.maximumTaskTextByteCount + 1
        for taskID in 1...taskCount {
            try writeTask(
                #"{"id":"\#(taskID)","subject":"\#(subject)","status":"pending"}"#,
                named: "\(taskID).json",
                in: sessionDirectory
            )
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.snapshotTextTooLarge(
            limit: ClaudeTaskSnapshotLoader.maximumSnapshotTextByteCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "text-overflow")
        }
    }

    @Test("Task snapshots accept the entry and file-size boundaries")
    func acceptsResourceBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("boundary", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let subject = String(
            repeating: "x",
            count: ClaudeTaskSnapshotLoader.maximumTaskTextByteCount
        )
        let prefix = "{\"id\":\"1\",\"subject\":\"\(subject)\",\"status\":\"pending\",\"padding\":\""
        let suffix = "\"}"
        let paddingCount = ClaudeTaskSnapshotLoader.maximumTaskFileByteCount
            - prefix.utf8.count
            - suffix.utf8.count
        let boundaryJSON = prefix + String(repeating: "x", count: paddingCount) + suffix
        try Data(boundaryJSON.utf8).write(to: sessionDirectory.appendingPathComponent("1.json"))
        for index in 2...ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount {
            try Data().write(to: sessionDirectory.appendingPathComponent("\(index).txt"))
        }

        let snapshot = try #require(
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "boundary")
        )

        #expect(snapshot.todos.count == 1)
        #expect(snapshot.todos[0].content.utf8.count == ClaudeTaskSnapshotLoader.maximumTaskTextByteCount)
    }

    @Test("Task snapshots reject a directory beyond the entry boundary")
    func rejectsDirectoryBeyondEntryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-entry-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("entry-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        for index in 0...ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount {
            try Data().write(to: sessionDirectory.appendingPathComponent("\(index).txt"))
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.tooManyDirectoryEntries(
            limit: ClaudeTaskSnapshotLoader.maximumDirectoryEntryCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "entry-overflow")
        }
    }

    @Test("Team-directory resolution rejects a task root beyond the entry boundary")
    func rejectsTaskRootBeyondEntryBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-root-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0...ClaudeTaskSnapshotLoader.maximumTaskRootEntryCount {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        #expect(throws: ClaudeTaskSnapshotLoaderError.tooManyTaskRootEntries(
            limit: ClaudeTaskSnapshotLoader.maximumTaskRootEntryCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(
                sessionID: "missing-session",
                taskIdentity: ClaudeTaskIdentity(id: "1", subject: "Missing task")
            )
        }
    }

    @Test("Task snapshots reject a task file beyond the byte boundary")
    func rejectsTaskFileBeyondByteBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-task-file-overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("file-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileName = "1.json"
        try Data(repeating: 0x20, count: ClaudeTaskSnapshotLoader.maximumTaskFileByteCount + 1)
            .write(to: sessionDirectory.appendingPathComponent(fileName))

        #expect(throws: ClaudeTaskSnapshotLoaderError.taskFileTooLarge(
            fileName: fileName,
            limit: ClaudeTaskSnapshotLoader.maximumTaskFileByteCount
        )) {
            try ClaudeTaskSnapshotLoader(tasksRootURL: root).load(sessionID: "file-overflow")
        }
    }

    private func writeTask(_ json: String, named name: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }
}
