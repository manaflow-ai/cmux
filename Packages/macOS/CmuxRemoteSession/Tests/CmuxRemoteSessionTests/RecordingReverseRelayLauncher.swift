import Foundation
import Testing
@testable import CmuxRemoteSession

/// Synchronous launcher callbacks cannot await; the lock protects only callback snapshots and a counter.
final class RecordingReverseRelayLauncher:
    RemoteReverseRelayLaunching,
    @unchecked Sendable
{
    let launches: AsyncStream<RecordedReverseRelayLaunch>
    let process = StubReverseRelayProcess()

    private let lock = NSLock()
    private var _launchCount = 0
    private var startupHandler: (@Sendable (any RemoteReverseRelayProcess) -> Void)?
    private var terminationHandler: (@Sendable (any RemoteReverseRelayProcess, String?) -> Void)?
    private let launchContinuation: AsyncStream<RecordedReverseRelayLaunch>.Continuation

    init() {
        (launches, launchContinuation) = AsyncStream.makeStream()
    }

    func launch(
        arguments: [String],
        environment: [String: String]?,
        startupMarker: String,
        startupHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess
        ) -> Void,
        terminationHandler: @escaping @Sendable (
            any RemoteReverseRelayProcess,
            String?
        ) -> Void
    ) throws -> any RemoteReverseRelayProcess {
        let reverseArgumentIndex = try #require(arguments.firstIndex(of: "-R"))
        let reverseArgument = try #require(
            arguments.indices.contains(arguments.index(after: reverseArgumentIndex))
                ? arguments[arguments.index(after: reverseArgumentIndex)]
                : nil
        )
        let localRelayPort = try #require(
            Int(reverseArgument.split(separator: ":").last ?? "")
        )
        launchContinuation.yield(RecordedReverseRelayLaunch(
            arguments: arguments,
            localRelayPort: localRelayPort,
            startupMarker: startupMarker
        ))
        lock.withLock {
            _launchCount += 1
            self.startupHandler = startupHandler
            self.terminationHandler = terminationHandler
        }
        return process
    }

    var launchCount: Int {
        lock.withLock { _launchCount }
    }

    func emitStartupReady() {
        let handler = lock.withLock { startupHandler }
        handler?(process)
    }

    func emitTermination(detail: String?) {
        let handler = lock.withLock { terminationHandler }
        handler?(process, detail)
    }
}
