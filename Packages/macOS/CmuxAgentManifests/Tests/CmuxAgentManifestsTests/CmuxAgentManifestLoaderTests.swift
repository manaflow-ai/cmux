import CmuxCore
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxAgentManifests

@Suite("Agent manifest loading")
struct CmuxAgentManifestLoaderTests {
    @Test("Bundled manifests validate and retain the built-in process identities")
    func bundledManifestsPinCurrentIdentities() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        #expect(snapshot.entries.map(\.manifest.id) == [
            "antigravity", "campfire", "grok", "hermes-agent", "kimi", "omp", "pi",
        ])

        let cases: [(String?, String?, CmuxAgentProcessSnapshot)] = [
            ("antigravity", "primary", .init(processName: "agy")),
            ("antigravity", "primary", .init(processName: "antigravity")),
            ("campfire", "native", .init(processName: "campfire")),
            ("campfire", "javascript-entrypoint", .init(processName: "bun", arguments: ["bun", "packages/session/bin/campfire.ts"])),
            ("campfire", "javascript-entrypoint", .init(processName: "node", arguments: ["node", "packages/session/dist/campfire"])),
            ("campfire", "javascript-entrypoint", .init(processName: "deno", arguments: ["deno", "packages/session/bin/campfire.ts"])),
            ("campfire", "javascript-entrypoint", .init(processName: "tsx", arguments: ["tsx", "packages/session/bin/campfire.ts"])),
            ("campfire", "javascript-entrypoint", .init(processName: "ts-node", arguments: ["ts-node", "packages/session/bin/campfire.ts"])),
            ("grok", "primary", .init(processName: "grok")),
            ("grok", "primary", .init(processName: "grok-macos-aarch64")),
            ("grok", "primary", .init(processName: "grok-macos-aarch")),
            ("hermes-agent", "native", .init(processName: "hermes")),
            ("hermes-agent", "native", .init(processName: "hermes-agent")),
            ("hermes-agent", "python-entrypoint", .init(processName: "python", arguments: ["python", "hermes-agent"])),
            ("hermes-agent", "python-entrypoint", .init(processName: "python3", arguments: ["python3", "-m", "hermes-agent"])),
            ("hermes-agent", "python-entrypoint", .init(processName: "python3", arguments: ["python3", "-X", "dev", "-m", "hermes-agent"])),
            ("hermes-agent", "python-entrypoint", .init(processName: "python3", arguments: ["python3", "--", "/opt/bin/hermes"])),
            ("kimi", "primary", .init(processName: "kimi")),
            ("kimi", "primary", .init(processName: "kimi-cli")),
            ("kimi", "primary", .init(processName: "kimi-code")),
            ("omp", "primary", .init(processName: "omp")),
            ("omp", "package-entrypoint", .init(processName: "bun", arguments: ["bun", "@oh-my-pi/pi-coding-agent"])),
            ("omp", "package-entrypoint", .init(processName: "node", arguments: ["node", "/opt/@oh-my-pi/pi-coding-agent/index.js"])),
            ("pi", "primary", .init(processName: "pi", arguments: ["pi"])),
            (nil, nil, .init(processName: "bash", arguments: ["bash", "pi"])),
            (nil, nil, .init(processName: "node", arguments: ["node", "other.ts"])),
            (nil, nil, .init(processName: "ruby", arguments: ["ruby", "packages/session/bin/campfire.ts"])),
            (nil, nil, .init(processName: "python3", arguments: ["python3", "-c", "print('hermes-agent')"])),
            (nil, nil, .init(processName: "python3", arguments: ["python3", "-m", "other"])),
            (nil, nil, .init(processName: "unrelated", arguments: ["unrelated"])),
        ]
        for (expectedID, expectedMatcherID, process) in cases {
            let result = snapshot.engine.detect(process: process)
            #expect(result.agentID == expectedID, "\(process.processName): \(process.arguments)")
            #expect(result.processMatcherID == expectedMatcherID, "\(process.processName): \(process.arguments)")
            #expect(result.source == (expectedID == nil ? nil : .bundled))
        }
    }

    @Test("Built-in state rules cover every declarative lifecycle state")
    func bundledStateClassifications() throws {
        let snapshot = try CmuxAgentManifestLoader.bundled().load()
        for entry in snapshot.entries {
            #expect(Set(entry.manifest.states.map(\.state)) == Set(CmuxAgentDetectionState.allCases))
            let process = CmuxAgentProcessSnapshot(
                processName: entry.manifest.process.matchers.first?.processNames.first ?? entry.manifest.id,
                arguments: [entry.manifest.id]
            )
            let positiveSamples: [(String, CmuxAgentClassification, String, String)] = [
                ("Approve this permission?", .permissionPrompt, "permission-prompt", "screenRegex[0]"),
                ("Waiting for input", .blocked, "blocked", "screenRegex[0]"),
                (
                    "Waiting"
                        + String(repeating: " ", count: 128)
                        + "for"
                        + String(repeating: " ", count: 128)
                        + "input",
                    .blocked,
                    "blocked",
                    "screenRegex[0]"
                ),
                ("Question " + String(repeating: "context ", count: 128) + "?", .blocked, "blocked", "screenRegex[0]"),
                ("Task completed", .done, "done", "screenRegex[0]"),
                ("⠋ working", .working, "working", "screenRegex[0]"),
                ("Agent is thinking", .working, "working", "screenRegex[1]"),
                ("rEaDy", .idle, "idle", "screenRegex[0]"),
                ("Working. Approve this permission?", .permissionPrompt, "permission-prompt", "screenRegex[0]"),
                ("Task completed but waiting for input", .blocked, "blocked", "screenRegex[0]"),
                ("Task completed; still working", .done, "done", "screenRegex[0]"),
                ("Ready and working", .working, "working", "screenRegex[1]"),
            ]
            for (screen, expected, expectedRuleID, expectedConditionID) in positiveSamples {
                let result = snapshot.engine.detect(process: process, screen: screen)
                let traceFree = snapshot.engine.classify(
                    manifestID: entry.manifest.id,
                    screen: screen
                )
                #expect(result.classification == expected, "\(entry.manifest.id): \(screen)")
                #expect(result.agentID == entry.manifest.id)
                #expect(result.source == .bundled)
                #expect(result.stateRuleID == expectedRuleID)
                #expect(traceFree.classification == expected)
                #expect(traceFree.stateRuleID == expectedRuleID)
                #expect(result.trace.contains {
                    $0.phase == .state
                        && $0.ruleID == expectedRuleID
                        && $0.conditionID == expectedConditionID
                        && $0.matched
                })
            }
            let askMe = snapshot.engine.detect(process: process, screen: "Ask me")
            if ["omp", "pi"].contains(entry.manifest.id) {
                #expect(askMe.classification == .idle)
                #expect(askMe.stateRuleID == "idle")
            } else {
                #expect(askMe.classification == .unknown)
                #expect(askMe.stateRuleID == nil)
            }
            for screen in ["approval is not requested", "ordinary output", "completedness"] {
                let result = snapshot.engine.detect(process: process, screen: screen)
                #expect(result.agentID == entry.manifest.id)
                #expect(result.classification == .unknown, "\(entry.manifest.id): negative fixture \(screen)")
                #expect(result.stateRuleID == nil)
            }
        }
    }

    @Test("Duplicate bundled ids fail before a catalog is published")
    func duplicateBundledIDsFailClosed() throws {
        let manifest = Data(#"{"id":"same","process":{"matchers":[{"processNames":["same"]}]}}"#.utf8)
        do {
            _ = try CmuxAgentManifestLoader(bundledManifestData: [manifest, manifest]).load()
            Issue.record("duplicate bundled ids were accepted")
        } catch let error as CmuxAgentManifestLoadError {
            guard case let .duplicateID(id, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(id == "same")
        }
    }

    @Test("An override directory path must remain a directory")
    func invalidOverrideDirectoryFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data(#"{"id":"fixture","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        do {
            _ = try CmuxAgentManifestLoader(bundledManifestData: [manifest], userDirectory: root).load()
            Issue.record("file override path was accepted")
        } catch let error as CmuxAgentManifestLoadError {
            guard case let .invalidFile(path, reason) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(path == root.path)
            #expect(reason.contains("directory"))
        }
    }

    @Test("User overrides replace or add manifests without code changes")
    func userOverridesAndNewAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let userDirectory = root.appendingPathComponent("agent-detection")
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Data(#"{"id":"fixture","displayName":"Fixture","process":{"matchers":[{"id":"base","processNames":["fixture"]}]}}"#.utf8)
        let override = Data(#"{"id":"fixture","displayName":"Fixture Override","process":{"matchers":[{"id":"override","processNames":["fixture-wrapper"]}]}}"#.utf8)
        try override.write(to: userDirectory.appendingPathComponent("fixture.json"))
        let newAgent = Data(#"{"id":"new-agent","process":{"matchers":[{"processNames":["new-agent"]}]},"states":[{"id":"done","state":"done","screenContains":["finished"]}]}"#.utf8)
        try newAgent.write(to: userDirectory.appendingPathComponent("new-agent.json"))

        let snapshot = try CmuxAgentManifestLoader(
            bundledManifestData: [base],
            userDirectory: userDirectory
        ).load()
        #expect(snapshot.entries.map { $0.manifest.id } == ["fixture", "new-agent"])
        #expect(snapshot.entry(id: "fixture")?.manifest.displayName == "Fixture Override")
        #expect(snapshot.entry(id: "fixture")?.manifest.process.matchers.first?.id == "override")
        #expect(snapshot.entry(id: "fixture")?.source == .user)
        #expect(snapshot.entry(id: "new-agent")?.source == .user)
    }

    @Test("Replace strategy does not inherit bundled arrays")
    func replaceOverrideStrategy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = Data(#"{"id":"fixture","displayName":"Bundled","process":{"matchers":[{"processNames":["fixture"]}]},"states":[{"id":"idle","state":"idle","screenContains":["ready"]}]}"#.utf8)
        let replacement = Data(#"{"mergeStrategy":"replace","id":"fixture","process":{"matchers":[{"processNames":["replacement"]}]},"states":[{"id":"done","state":"done","screenContains":["finished"]}]}"#.utf8)
        try replacement.write(to: root.appendingPathComponent("fixture.json"))
        let snapshot = try CmuxAgentManifestLoader(bundledManifestData: [bundled], userDirectory: root).load()
        #expect(snapshot.entry(id: "fixture")?.manifest.displayName == "fixture")
        #expect(snapshot.entry(id: "fixture")?.manifest.states.map(\.state) == [.done])
    }

    @Test("Override filename and merge strategy errors are explicit")
    func overrideFilenameAndStrategyErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data(#"{"id":"fixture","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        try manifest.write(to: root.appendingPathComponent("wrong.json"))
        do {
            _ = try CmuxAgentManifestLoader(bundledManifestData: [manifest], userDirectory: root).load()
            Issue.record("mismatched filename was accepted")
        } catch let error as CmuxAgentManifestLoadError {
            guard case .invalidOverrideFilename = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("wrong.json"))
        let invalidStrategy = Data(#"{"id":"fixture","mergeStrategy":true,"process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        try invalidStrategy.write(to: root.appendingPathComponent("fixture.json"))
        do {
            _ = try CmuxAgentManifestLoader(bundledManifestData: [manifest], userDirectory: root).load()
            Issue.record("non-string merge strategy was accepted")
        } catch let error as CmuxAgentManifestLoadError {
            #expect(error.description.contains("mergeStrategy"))
        }
    }

    @Test("A failed hot reload preserves the last-known-good snapshot")
    func failedReloadRetainsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = Data(#"{"id":"fixture","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        let loader = CmuxAgentManifestLoader(bundledManifestData: [good], userDirectory: root)
        let store = try CmuxAgentManifestStore(loader: loader)
        let initial = await store.snapshot()
        try Data("{ nope".utf8).write(to: root.appendingPathComponent("fixture.json"))
        guard case .failure = await store.reload() else {
            Issue.record("malformed reload unexpectedly succeeded")
            return
        }
        #expect(await store.snapshot() == initial)
    }

    @Test("Malformed user files retain bundled behavior for stateless consumers")
    func bundledFallbackOutcome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-manifest-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundled = Data(#"{"id":"fixture","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        try Data("{ nope".utf8).write(to: root.appendingPathComponent("fixture.json"))
        let outcome = try CmuxAgentManifestLoader(
            bundledManifestData: [bundled],
            userDirectory: root
        ).loadWithBundledFallback(generation: 7)

        #expect(outcome.snapshot.generation == 7)
        #expect(outcome.snapshot.entries.map(\.manifest.id) == ["fixture"])
        #expect(outcome.snapshot.entries.first?.source == .bundled)
        #expect(outcome.rejectedOverrideError != nil)
        #expect(outcome.snapshot.engine.detect(process: .init(processName: "fixture")).agentID == "fixture")
    }

    @Test("Bundled failures never masquerade as an override fallback")
    func bundledFallbackStillRejectsBrokenBundle() {
        do {
            _ = try CmuxAgentManifestLoader(
                bundledManifestData: [Data("{ nope".utf8)]
            ).loadWithBundledFallback()
            Issue.record("Malformed bundled data was accepted")
        } catch let error as CmuxAgentManifestLoadError {
            #expect(error.description.contains("bundle/agent-0.json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("The file watcher reloads repairs without losing the last good catalog")
    func fileWatcherReloadsAndRecovers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-manifest-watch-\(UUID().uuidString)", isDirectory: true)
        let userDirectory = root.appendingPathComponent("agent-detection", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundled = Data(#"{"id":"fixture","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        let loader = CmuxAgentManifestLoader(
            bundledManifestData: [bundled],
            userDirectory: userDirectory
        )
        let store = try CmuxAgentManifestStore(loader: loader)
        let watcher = FileWatcher(path: userDirectory.path, throttle: .milliseconds(10))
        await store.startWatching(events: watcher.events)

        let firstUpdate = Task { () -> CmuxAgentManifestSnapshot? in
            var iterator = store.updates.makeAsyncIterator()
            return await iterator.next()
        }
        let validOverride = Data(#"{"id":"fixture","displayName":"Edited","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        try validOverride.write(to: userDirectory.appendingPathComponent("fixture.json"), options: .atomic)
        let edited = await Self.awaitValue(firstUpdate, within: .seconds(5))
        #expect(edited?.entry(id: "fixture")?.manifest.displayName == "Edited")

        try Data("{ nope".utf8).write(to: userDirectory.appendingPathComponent("fixture.json"), options: .atomic)
        let rejected = await store.reload()
        guard case .failure = rejected else {
            Issue.record("Malformed watcher input was accepted")
            return
        }
        #expect(await store.snapshot().entry(id: "fixture")?.manifest.displayName == "Edited")
        #expect(await store.reloadError() != nil)

        let repairedUpdate = Task { () -> CmuxAgentManifestSnapshot? in
            var iterator = store.updates.makeAsyncIterator()
            return await iterator.next()
        }
        let repaired = Data(#"{"id":"fixture","displayName":"Repaired","process":{"matchers":[{"processNames":["fixture"]}]}}"#.utf8)
        try repaired.write(to: userDirectory.appendingPathComponent("fixture.json"), options: .atomic)
        let recovered = await Self.awaitValue(repairedUpdate, within: .seconds(5))
        #expect(recovered?.entry(id: "fixture")?.manifest.displayName == "Repaired")
        #expect(await store.reloadError() == nil)

        await store.stopWatching()
        await watcher.stop()
    }

    private static func awaitValue<T: Sendable & Equatable>(
        _ task: Task<T?, Never>,
        within duration: Duration
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            task.cancel()
            return value
        }
    }
}
