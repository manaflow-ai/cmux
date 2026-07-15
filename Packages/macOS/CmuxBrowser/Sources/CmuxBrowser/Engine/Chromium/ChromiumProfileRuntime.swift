public import Foundation

/// Owns one persistent Chromium process and CDP connection for a cmux browser profile.
///
/// Every simultaneously open pane for the profile receives its own target on the
/// shared process. This preserves Chromium's process-wide profile lock while
/// allowing cookies and site storage to persist in one profile directory.
public actor ChromiumProfileRuntime {
    private let userDataDirectory: URL
    private let processController: ChromiumProcessController
    private var connection: CDPConnection?
    private var startupTask: Task<ChromiumProfileRuntimeConnection, any Error>?
    private var shutdownTask: Task<Void, Never>?
    private var activeTargetIDs: Set<String> = []
    private var pendingAcquisitionCount = 0
    private var lifecycleGeneration = 0

    /// Creates a profile-scoped Chromium runtime.
    ///
    /// Construction does not launch Chromium. The first engine session starts the
    /// process, and the final released target stops it without deleting profile data.
    ///
    /// - Parameter userDataDirectory: The persistent user-data directory for the cmux profile.
    public init(userDataDirectory: URL) {
        self.userDataDirectory = userDataDirectory
        self.processController = ChromiumProcessController()
    }

    func acquireTarget(
        application: BrowserApplication,
        width: Int,
        height: Int
    ) async throws -> ChromiumProfileRuntimeLease {
        pendingAcquisitionCount += 1
        do {
            let shared = try await connected(application: application)
            let generation = lifecycleGeneration
            try Task.checkCancellation()
            let created = try await shared.connection.send(
                method: "Target.createTarget",
                parameters: [
                    "url": .string("about:blank"),
                    "width": .number(Double(width)),
                    "height": .number(Double(height)),
                ]
            )
            guard let targetID = created.objectValue?["targetId"]?.stringValue else {
                throw BrowserEngineSessionError.chromiumProtocol("Chromium did not create a page target.")
            }
            guard generation == lifecycleGeneration else {
                _ = try? await shared.connection.send(
                    method: "Target.closeTarget",
                    parameters: ["targetId": .string(targetID)]
                )
                throw CancellationError()
            }
            let attached = try await shared.connection.send(
                method: "Target.attachToTarget",
                parameters: ["targetId": .string(targetID), "flatten": .bool(true)]
            )
            guard let sessionID = attached.objectValue?["sessionId"]?.stringValue else {
                _ = try? await shared.connection.send(
                    method: "Target.closeTarget",
                    parameters: ["targetId": .string(targetID)]
                )
                throw BrowserEngineSessionError.chromiumProtocol("Chromium did not attach to the page target.")
            }
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                _ = try? await shared.connection.send(
                    method: "Target.closeTarget",
                    parameters: ["targetId": .string(targetID)]
                )
                throw CancellationError()
            }
            activeTargetIDs.insert(targetID)
            let lease = ChromiumProfileRuntimeLease(
                connection: shared.connection,
                targetID: targetID,
                sessionID: sessionID,
                processIdentifier: shared.processIdentifier
            )
            pendingAcquisitionCount -= 1
            return lease
        } catch {
            pendingAcquisitionCount -= 1
            await shutDownIfUnused()
            throw error
        }
    }

    func releaseTarget(_ targetID: String) async {
        guard activeTargetIDs.remove(targetID) != nil else { return }
        if let connection {
            _ = try? await connection.send(
                method: "Target.closeTarget",
                parameters: ["targetId": .string(targetID)]
            )
        }
        await shutDownIfUnused()
    }

    /// Stops every target and the profile process while retaining on-disk data.
    public func close() async {
        lifecycleGeneration &+= 1
        startupTask?.cancel()
        startupTask = nil
        activeTargetIDs.removeAll()
        await shutDown()
    }

    private func connected(application: BrowserApplication) async throws -> ChromiumProfileRuntimeConnection {
        if let shutdownTask {
            await shutdownTask.value
            if self.shutdownTask != nil {
                self.shutdownTask = nil
            }
            return try await connected(application: application)
        }
        if let connection {
            if await connection.isOpen() {
                return ChromiumProfileRuntimeConnection(
                    connection: connection,
                    processIdentifier: await processController.processIdentifier()
                )
            }
            self.connection = nil
            activeTargetIDs.removeAll()
            await shutDown()
            return try await connected(application: application)
        }

        let generation = lifecycleGeneration
        let task: Task<ChromiumProfileRuntimeConnection, any Error>
        if let startupTask {
            task = startupTask
        } else {
            let processController = processController
            let userDataDirectory = userDataDirectory
            task = Task<ChromiumProfileRuntimeConnection, any Error> {
                let endpoint = try await processController.start(
                    application: application,
                    userDataDirectory: userDataDirectory
                )
                let connection = CDPConnection(url: endpoint)
                await connection.connect()
                return ChromiumProfileRuntimeConnection(
                    connection: connection,
                    processIdentifier: await processController.processIdentifier()
                )
            }
            startupTask = task
        }
        do {
            let shared = try await task.value
            guard generation == lifecycleGeneration else {
                await shared.connection.close()
                throw CancellationError()
            }
            connection = shared.connection
            startupTask = nil
            return shared
        } catch {
            if generation == lifecycleGeneration {
                startupTask = nil
            }
            await processController.close()
            throw error
        }
    }

    private func shutDownIfUnused() async {
        guard activeTargetIDs.isEmpty, pendingAcquisitionCount == 0 else { return }
        await shutDown()
    }

    private func shutDown() async {
        if let shutdownTask {
            await shutdownTask.value
            self.shutdownTask = nil
            return
        }
        guard connection != nil || startupTask != nil else {
            await processController.close()
            return
        }
        lifecycleGeneration &+= 1
        startupTask?.cancel()
        startupTask = nil
        let connection = connection
        self.connection = nil
        let processController = processController
        let task = Task {
            await connection?.close()
            await processController.close()
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }
}
