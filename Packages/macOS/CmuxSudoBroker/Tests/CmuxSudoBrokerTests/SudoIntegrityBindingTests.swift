@testable import CmuxSudoBroker
import Darwin
import Foundation
import Testing

@Suite("Sudo integrity binding", .timeLimit(.minutes(1)))
struct SudoIntegrityBindingTests {
    // MARK: Reviewed-script digest

    @Test("Approval records the SHA-256 of the exact reviewed bytes")
    func approvalRecordsReviewedDigest() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        _ = try fixture.enqueue(id: "digest-recorded", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)

        let transition = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )

        guard case .approved(let manifest) = transition else {
            Issue.record("approval did not produce a manifest")
            return
        }
        #expect(manifest.reviewedScriptSHA256 == SudoSHA256.hex(Data("echo test\n".utf8)))
        #expect(fixture.store.manifest(id: pending.request.id) == manifest)
    }

    @Test("User runner refuses bytes whose digest differs from the approved manifest")
    func runnerRefusesReviewedDigestMismatch() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "digest-mismatch", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let spawner = RecordingSpawner()

        // The capability carries bytes other than the reviewed "echo test\n".
        try runRunner(
            fixture: fixture,
            requestID: request.id,
            capabilityBytes: Data("echo pwned\n".utf8),
            spawner: spawner,
            helperResolver: StaticSudoHelperResolver(),
            now: now
        )

        #expect(spawner.commands.isEmpty)
        let result = try #require(fixture.store.authoritativeResult(id: request.id))
        #expect(result.status == .failed)
        #expect(result.errorCode == .stagingFailed)
    }

    @Test("User runner refuses a manifest without a reviewed digest")
    func runnerRefusesUnboundManifest() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "digest-missing", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let manifest = try #require(fixture.store.manifest(id: request.id))
        let unbound = SudoExecutionManifest(
            id: manifest.id,
            requesterIdentity: manifest.requesterIdentity,
            currentDirectory: manifest.currentDirectory,
            directoryIdentity: manifest.directoryIdentity,
            deadline: manifest.deadline
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unbound).write(
            to: fixture.paths.executions.appendingPathComponent("\(request.id).json")
        )
        let spawner = RecordingSpawner()

        try runRunner(
            fixture: fixture,
            requestID: request.id,
            capabilityBytes: Data(pending.script.utf8),
            spawner: spawner,
            helperResolver: StaticSudoHelperResolver(),
            now: now
        )

        #expect(spawner.commands.isEmpty)
        #expect(fixture.store.authoritativeResult(id: request.id)?.errorCode == .stagingFailed)
    }

    @Test("Root receiver refuses transported bytes that do not match the reviewed digest")
    func rootReceiverRefusesDigestMismatch() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        var masterDescriptor: Int32 = -1
        var slaveDescriptor: Int32 = -1
        #expect(openpty(&masterDescriptor, &slaveDescriptor, nil, nil, nil) == 0)
        try #require(masterDescriptor >= 0 && slaveDescriptor >= 0)
        defer {
            Darwin.close(masterDescriptor)
            Darwin.close(slaveDescriptor)
        }
        let reviewed = Data("echo safe\n".utf8)
        let substituted = Data("echo evil\n".utf8)
        try #require(reviewed.count == substituted.count)
        Self.feedAfterReadyMarker(substituted, to: masterDescriptor)
        let receiver = SudoPrivilegedScriptReceiver(
            inputDescriptor: slaveDescriptor,
            outputDescriptor: slaveDescriptor,
            temporaryDirectoryURL: fixture.root
        )
        var operationRan = false

        #expect(throws: SudoPrivilegedScriptReceiver.Failure.digestMismatch) {
            try receiver.withReceivedDescriptor(
                expectedByteCount: reviewed.count,
                expectedSHA256: SudoSHA256.hex(reviewed),
                deadline: Date.now.addingTimeInterval(10)
            ) { _ in operationRan = true }
        }
        #expect(!operationRan)
    }

    @Test("Root executor rejects the legacy argument shape without a digest")
    func rootExecutorRequiresDigestArgument() {
        let executor = SudoPrivilegedExecutor(
            receiver: SudoPrivilegedScriptReceiver(inputDescriptor: -1, outputDescriptor: -1),
            supervisor: SudoPrivilegedProcessSupervisor(),
            effectiveUserID: { 0 },
            errorDescriptor: -1
        )
        let token = SudoExecutionControlMarkers().token

        #expect(executor.run(arguments: ["4", "1900000000", "/tmp/x.sh", token]) == 2)
        #expect(executor.run(
            arguments: ["4", "1900000000", "/tmp/x.sh", "not-a-digest", token]
        ) == 2)
    }

    // MARK: Bundled helper authentication

    @Test("Runner refuses to spawn sudo when the app bundle signature is invalid")
    func runnerRefusesUnverifiedBundle() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "unsigned-bundle", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let checker = StubSudoCodeSignatureChecker(failure: .invalidSignature(-67_030))
        let spawner = RecordingSpawner()

        try runRunner(
            fixture: fixture,
            requestID: request.id,
            capabilityBytes: Data(pending.script.utf8),
            spawner: spawner,
            helperResolver: SudoBundledHelperResolver(policy: .testPolicy(), checker: checker),
            now: now
        )

        #expect(checker.calls.map(\.resourcePath) == ["Resources/bin/cmux"])
        #expect(spawner.commands.isEmpty)
        #expect(fixture.store.authoritativeResult(id: request.id)?.errorCode == .processLaunchFailed)
    }

    @Test("Runner passes sudo only the root staging program, never the bundle helper path")
    func runnerStagesSealedExecutor() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let now = Date.now
        let request = try fixture.enqueue(id: "staged-executor", createdAt: now)
        let pending = try #require(fixture.store.pendingRequests().first)
        _ = try fixture.store.transitionToApproved(
            pending: pending, now: now, executionGraceSeconds: 90
        )
        let sealedDigest = Data(repeating: 0x5a, count: 32)
        let policy = SudoBundledHelperPolicy.testPolicy()
        let spawner = RecordingSpawner()

        try runRunner(
            fixture: fixture,
            requestID: request.id,
            capabilityBytes: Data(pending.script.utf8),
            spawner: spawner,
            helperResolver: SudoBundledHelperResolver(
                policy: policy,
                checker: StubSudoCodeSignatureChecker(digest: sealedDigest)
            ),
            now: now
        )

        let command = try #require(spawner.commands.first)
        let sudoIndex = try #require(command.arguments.firstIndex(of: "/usr/bin/sudo"))
        let afterSudo = Array(command.arguments[(sudoIndex + 5)...])
        #expect(afterSudo[0] == "/bin/sh")
        #expect(afterSudo[1] == "-c")
        #expect(afterSudo[3] == SudoHelperStagingCommand.argumentZero)
        #expect(afterSudo[4] == "/Applications/cmux.app/Contents/Resources/bin/cmux")
        #expect(afterSudo[5] == String(repeating: "5a", count: 32))
        #expect(afterSudo[7] == policy.executorRequirement.text)
        #expect(afterSudo[10] == SudoPrivilegedExecutor.hiddenCommand)
        #expect(afterSudo[14] == SudoSHA256.hex(Data(pending.script.utf8)))
        #expect(afterSudo.last == command.controlMarkers.token)

        let inventory = SudoOrphanProcessInventory(
            inspector: SequencedSudoProcessInspector(
                processIdentifier: 77,
                identities: [TestRunnerLauncher.defaultRunnerIdentity, TestRunnerLauncher.defaultRunnerIdentity],
                arguments: command.arguments
            )
        ).identitiesByScriptPath(approvedScriptURLs: [fixture.store.approvedScriptURL(id: request.id)])
        #expect(inventory.values.flatMap { $0 } == [TestRunnerLauncher.defaultRunnerIdentity])
    }

    @Test("Root staging executes a helper whose copy matches the sealed digest")
    func stagingRunsMatchingHelper() throws {
        let staging = try StagingHarness()
        defer { staging.remove() }
        let helperBytes = Data("printf 'staged:%s' \"$1\"\n".utf8)
        let source = try staging.writeSource(helperBytes)

        let run = try staging.run(
            helper: SudoVerifiedHelper(
                sourceURL: source,
                sha256: SudoSHA256.hex(helperBytes),
                requirement: nil,
                interpreter: "/bin/bash"
            ),
            helperArguments: ["ok"]
        )

        #expect(run.status == 0)
        #expect(run.standardOutput == "staged:ok")
        #expect(staging.stagingDirectoriesAreRemoved())
    }

    @Test("Root staging refuses a helper whose bytes differ from the sealed digest")
    func stagingRefusesHelperDigestMismatch() throws {
        let staging = try StagingHarness()
        defer { staging.remove() }
        let sealedBytes = Data("echo sealed\n".utf8)
        let swappedBytes = Data(": > '\(staging.root.path)/executed'\n".utf8)
        let source = try staging.writeSource(swappedBytes)
        // The checker vouches for the sealed content; the file on disk was swapped.
        let resolver = SudoBundledHelperResolver(
            policy: .testPolicy(),
            checker: StubSudoCodeSignatureChecker(
                digest: Data(SudoSHA256.hex(sealedBytes).hexBytes)
            )
        )
        var helper = try resolver.touchIDSetupScript()
        helper = SudoVerifiedHelper(
            sourceURL: source,
            sha256: helper.sha256,
            requirement: helper.requirement,
            interpreter: helper.interpreter
        )
        let marker = SudoExecutionControlMarkers().transportFailed

        let run = try staging.run(helper: helper, failureMarker: marker)

        #expect(run.status == 125)
        #expect(run.standardError == String(decoding: marker, as: UTF8.self))
        #expect(!FileManager.default.fileExists(atPath: staging.root.appendingPathComponent("executed").path))
        #expect(staging.stagingDirectoriesAreRemoved())
    }

    @Test("Root staging bounds the helper snapshot size")
    func stagingRefusesOversizedHelper() throws {
        let staging = try StagingHarness(maximumHelperBytes: 16)
        defer { staging.remove() }
        let helperBytes = Data(repeating: 0x23, count: 17)
        let source = try staging.writeSource(helperBytes)

        let run = try staging.run(
            helper: SudoVerifiedHelper(
                sourceURL: source,
                sha256: SudoSHA256.hex(helperBytes),
                requirement: nil,
                interpreter: "/bin/bash"
            )
        )

        #expect(run.status == 125)
    }

    @Test("Root staging checks a Mach-O helper against the pinned requirement")
    func stagingEnforcesCodeRequirement() throws {
        let staging = try StagingHarness()
        defer { staging.remove() }
        let helperBytes = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        let source = try staging.writeSource(helperBytes)
        let foreignTeam = try #require(
            SudoCodeSigningRequirement.developerID(teamIdentifier: "7WLXT3NR37")
        )

        let refused = try staging.run(
            helper: SudoVerifiedHelper(
                sourceURL: source,
                sha256: SudoSHA256.hex(helperBytes),
                requirement: foreignTeam,
                interpreter: nil
            )
        )
        let accepted = try staging.run(
            helper: SudoVerifiedHelper(
                sourceURL: source,
                sha256: SudoSHA256.hex(helperBytes),
                requirement: SudoCodeSigningRequirement(text: "anchor apple"),
                interpreter: nil
            )
        )

        #expect(refused.status == 125)
        #expect(accepted.status == 0)
    }

    @Test("Debug policy pins the executor to the running code's designated requirement")
    func debugPolicyPinsRunningIdentity() throws {
        let bundle = URL(fileURLWithPath: "/tmp/cmux DEV.app")
        let adHoc = try #require(SudoBundledHelperPolicy.runningCodeIdentity(
            appBundleURL: bundle,
            reader: StubRunningIdentity(requirement: "cdhash H\"00\"", team: nil)
        ))
        #expect(adHoc.executorRequirement.text == "cdhash H\"00\"")
        #expect(adHoc.bundleRequirement == nil)

        let teamSigned = try #require(SudoBundledHelperPolicy.runningCodeIdentity(
            appBundleURL: bundle,
            reader: StubRunningIdentity(requirement: "identifier cmux", team: "ABCDE12345")
        ))
        #expect(teamSigned.bundleRequirement?.text.contains("\"ABCDE12345\"") == true)

        #expect(SudoBundledHelperPolicy.runningCodeIdentity(
            appBundleURL: bundle,
            reader: StubRunningIdentity(requirement: nil, team: nil)
        ) == nil)
        #expect(SudoBundledHelperPolicy.developerID(
            appBundleURL: bundle,
            teamIdentifier: "7WLXT3NR37\" or anchor apple generic"
        ) == nil)
    }

    // MARK: Helpers

    private func runRunner(
        fixture: SudoTestFixture,
        requestID: String,
        capabilityBytes: Data,
        spawner: RecordingSpawner,
        helperResolver: any SudoBundledHelperResolving,
        now: Date
    ) throws {
        let parentURL = URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux")
        let inspector = TestRunnerBootstrapInspector(
            parentProcessIdentifier: 2_000_000_000,
            parentExecutableURL: parentURL,
            runnerProcessIdentifier: getpid()
        )
        let capability = SudoReviewedScriptCapability(
            bytes: capabilityBytes,
            temporaryDirectoryURL: fixture.root
        )
        try capability.withDescriptor { descriptor in
            _ = SudoExecutionRunner(
                store: fixture.store,
                pam: TestPAMChecker(enabled: true),
                inspector: inspector,
                parentValidator: SudoRunnerParentValidator(
                    inspector: inspector,
                    parentProcessIdentifier: { 2_000_000_000 }
                ),
                processRunner: SudoBoundedProcessRunner(
                    spawner: spawner,
                    inspector: inspector,
                    signaler: TestSudoProcessSignaler()
                ),
                reviewedScriptReader: SudoReviewedScriptReader(descriptor: descriptor),
                expectedParentExecutableURL: parentURL,
                helperResolver: helperResolver,
                messages: .testMessages,
                now: { now }
            ).run(requestID: requestID)
        }
    }

    private static func feedAfterReadyMarker(_ bytes: Data, to descriptor: Int32) {
        let marker = SudoExecutionControlMarkers().inputReady
        Thread.detachNewThread {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 64)
            while !received.contains(marker) {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    received.append(contentsOf: buffer.prefix(count))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
            bytes.withUnsafeBytes { pointer in
                _ = Darwin.write(descriptor, pointer.baseAddress, bytes.count)
            }
        }
    }
}

/// Records spawn attempts and then reports a synthetic, already-absent process.
private final class RecordingSpawner: SudoProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SudoExecutionCommand] = []

    var commands: [SudoExecutionCommand] { lock.withLock { recorded } }

    func spawn(_ command: SudoExecutionCommand) throws -> SudoSpawnedProcess {
        lock.withLock { recorded.append(command) }
        throw POSIXError(.EPERM)
    }
}

private struct StubRunningIdentity: SudoRunningCodeIdentityReading {
    let requirement: String?
    let team: String?

    func designatedRequirement() throws -> SudoCodeSigningRequirement {
        guard let requirement else { throw SudoCodeSignatureError.runningCode(-1) }
        return SudoCodeSigningRequirement(text: requirement)
    }

    func teamIdentifier() -> String? { team }
}

/// Runs the root staging program as the test user against a private staging parent.
private struct StagingHarness {
    struct Run {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    let root: URL
    let stagingParent: URL
    let command: SudoHelperStagingCommand

    init(maximumHelperBytes: Int = 1_024 * 1_024) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sudo-staging-\(UUID().uuidString)", isDirectory: true)
        stagingParent = root.appendingPathComponent("root-owned", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingParent,
            withIntermediateDirectories: true
        )
        command = SudoHelperStagingCommand(
            stagingParent: stagingParent.path,
            maximumHelperBytes: maximumHelperBytes
        )
    }

    func writeSource(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("bundle-helper")
        try data.write(to: url)
        return url
    }

    func run(
        helper: SudoVerifiedHelper,
        failureMarker: Data = Data(),
        helperArguments: [String] = []
    ) throws -> Run {
        let arguments = command.arguments(
            helper: helper,
            failureMarker: failureMarker,
            helperArguments: helperArguments
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    func stagingDirectoriesAreRemoved() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: stagingParent.path)) ?? ["?"])
            .isEmpty
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension String {
    var hexBytes: [UInt8] {
        var bytes: [UInt8] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            bytes.append(UInt8(self[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
