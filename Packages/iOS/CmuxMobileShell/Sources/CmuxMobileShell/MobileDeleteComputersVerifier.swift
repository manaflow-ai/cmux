#if DEBUG
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
public import Foundation

/// DEBUG-only scenario runner used by the iOS UI test to prove computer deletion
/// updates the workspace list and refresh behavior.
@MainActor
public struct MobileDeleteComputersVerifier {
    /// Environment variable that enables the verifier route in DEBUG builds.
    public let environmentKey: String
    /// File name used for the JSON evidence written to Caches.
    public let evidenceFileName: String

    private let environment: [String: String]
    private let fileManager: FileManager

    /// Create a verifier with injectable process environment and filesystem
    /// dependencies so tests can run deterministically.
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        environmentKey: String = "CMUX_DELETE_COMPUTERS_VERIFIER",
        evidenceFileName: String = "cmux-delete-computers-verification.json"
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.environmentKey = environmentKey
        self.evidenceFileName = evidenceFileName
    }

    /// Whether the verifier route should replace the normal app UI.
    public var isEnabled: Bool {
        environment[environmentKey] == "1"
    }

    /// Run the delete-computers scenario and persist JSON evidence to Caches.
    public func runAndPersist() async -> MobileDeleteComputersVerificationResult {
        var result = await run()
        do {
            let url = try evidenceURL()
            let data = try JSONEncoder.prettyVerifierEncoder.encode(result)
            try data.write(to: url, options: [.atomic])
            result.evidencePath = url.path
            let updatedData = try JSONEncoder.prettyVerifierEncoder.encode(result)
            try updatedData.write(to: url, options: [.atomic])
        } catch {
            result.passed = false
            result.reason = "\(result.reason); failed to write evidence: \(error)"
        }
        return result
    }

    private func run() async -> MobileDeleteComputersVerificationResult {
        do {
            return try await runScenario()
        } catch {
            return MobileDeleteComputersVerificationResult(
                passed: false,
                reason: "Verifier threw \(error)",
                deletedHalfMacIDs: [],
                deletedAllMacIDs: [],
                halfRemovedAbsent: false,
                halfRemainingPresent: false,
                halfNoDisconnectedBanner: false,
                refreshPreservedHalfList: false,
                allRemoved: false,
                refreshPreservedEmptyList: false,
                checkpoints: [],
                evidencePath: nil
            )
        }
    }

    private func runScenario() async throws -> MobileDeleteComputersVerificationResult {
        let userID = "delete-computers-verifier-user"
        let teamID = "delete-computers-verifier-team"
        let store = DeleteComputersVerifierPairedMacStore(records: seededMacs(userID: userID, teamID: teamID))
        let identity = DeleteComputersVerifierIdentityProvider(userID: userID)
        let defaultsSuiteName = "delete-computers-verifier-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.set(false, forKey: "multiMacAggregation")
        let shell = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            connectedHostName: "Verifier Mac A",
            pairedMacStore: store,
            identityProvider: identity,
            teamIDProvider: { teamID },
            multiMacAggregationDefaults: defaults,
            forgottenMacStore: InMemoryPairedMacForgottenStore()
        )

        await shell.loadPairedMacs()
        shell.setWorkspaceStatesForTesting(seededWorkspaceStates(), foregroundMacDeviceID: "mac-a")
        let initial = checkpoint("initial", shell: shell)

        let halfDeleteIDs = ["mac-a", "mac-b"]
        for macID in halfDeleteIDs {
            await shell.forgetMac(macDeviceID: macID)
        }
        let afterHalfDelete = checkpoint("after-half-delete", shell: shell)

        await shell.reconnectOrRefresh()
        let afterHalfRefresh = checkpoint("after-half-refresh", shell: shell)

        let remainingDeleteIDs = ["mac-c", "mac-d"]
        for macID in remainingDeleteIDs {
            await shell.forgetMac(macDeviceID: macID)
        }
        let afterAllDelete = checkpoint("after-all-delete", shell: shell)

        await shell.reconnectOrRefresh()
        let afterAllRefresh = checkpoint("after-all-refresh", shell: shell)

        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let removedHalf = Set(halfDeleteIDs)
        let expectedRemaining = Set(["mac-c", "mac-d"])
        let halfRemovedAbsent = afterHalfDelete.workspaceMacIDs.allSatisfy { !removedHalf.contains($0) }
            && afterHalfRefresh.workspaceMacIDs.allSatisfy { !removedHalf.contains($0) }
        let halfRemainingPresent = Set(afterHalfDelete.workspaceMacIDs) == expectedRemaining
            && Set(afterHalfRefresh.workspaceMacIDs) == expectedRemaining
        let halfNoDisconnectedBanner = afterHalfDelete.workspaceListStatus == "connected"
            && afterHalfRefresh.workspaceListStatus == "connected"
        let refreshPreservedHalfList = afterHalfRefresh.workspaceIDs == afterHalfDelete.workspaceIDs
            && afterHalfRefresh.displayMacIDs == afterHalfDelete.displayMacIDs
        let allRemoved = afterAllDelete.workspaceIDs.isEmpty
            && afterAllDelete.displayMacIDs.isEmpty
        let refreshPreservedEmptyList = afterAllRefresh.workspaceIDs.isEmpty
            && afterAllRefresh.displayMacIDs.isEmpty
        let passed = halfRemovedAbsent
            && halfRemainingPresent
            && halfNoDisconnectedBanner
            && refreshPreservedHalfList
            && allRemoved
            && refreshPreservedEmptyList
        let reason = passed
            ? "PASS"
            : "halfRemovedAbsent=\(halfRemovedAbsent) halfRemainingPresent=\(halfRemainingPresent) halfNoDisconnectedBanner=\(halfNoDisconnectedBanner) refreshPreservedHalfList=\(refreshPreservedHalfList) allRemoved=\(allRemoved) refreshPreservedEmptyList=\(refreshPreservedEmptyList)"

        return MobileDeleteComputersVerificationResult(
            passed: passed,
            reason: reason,
            deletedHalfMacIDs: halfDeleteIDs,
            deletedAllMacIDs: halfDeleteIDs + remainingDeleteIDs,
            halfRemovedAbsent: halfRemovedAbsent,
            halfRemainingPresent: halfRemainingPresent,
            halfNoDisconnectedBanner: halfNoDisconnectedBanner,
            refreshPreservedHalfList: refreshPreservedHalfList,
            allRemoved: allRemoved,
            refreshPreservedEmptyList: refreshPreservedEmptyList,
            checkpoints: [initial, afterHalfDelete, afterHalfRefresh, afterAllDelete, afterAllRefresh],
            evidencePath: nil
        )
    }

    private func checkpoint(
        _ name: String,
        shell: MobileShellComposite
    ) -> MobileDeleteComputersVerificationCheckpoint {
        let workspaces = shell.workspaces.map { workspace in
            MobileDeleteComputersVerificationWorkspace(
                id: workspace.id.rawValue,
                name: workspace.name,
                macDeviceID: workspace.macDeviceID,
                status: workspace.macConnectionStatus.map(statusName)
            )
        }
        return MobileDeleteComputersVerificationCheckpoint(
            name: name,
            workspaceCount: workspaces.count,
            workspaceIDs: workspaces.map(\.id),
            workspaceMacIDs: Array(Set(workspaces.compactMap(\.macDeviceID))).sorted(),
            displayMacIDs: shell.displayPairedMacs.map(\.macDeviceID).sorted(),
            workspaceListStatus: statusName(shell.workspaceListConnectionStatus),
            pages: workspaces.chunkedForVerifier(pageSize: 5)
        )
    }

    private func seededMacs(userID: String, teamID: String) -> [MobilePairedMac] {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        return ["mac-a", "mac-b", "mac-c", "mac-d"].enumerated().map { index, id in
            MobilePairedMac(
                macDeviceID: id,
                displayName: "Verifier Mac \(String(UnicodeScalar(65 + index)!))",
                routes: [],
                createdAt: now.addingTimeInterval(Double(index)),
                lastSeenAt: now.addingTimeInterval(Double(index)),
                isActive: id == "mac-a",
                stackUserID: userID,
                teamID: teamID
            )
        }
    }

    private func seededWorkspaceStates() -> [String: MacWorkspaceState] {
        Dictionary(uniqueKeysWithValues: ["mac-a", "mac-b", "mac-c", "mac-d"].enumerated().map { index, macID in
            let letter = String(UnicodeScalar(65 + index)!)
            let workspaces = (1...3).map { workspaceIndex in
                MobileWorkspacePreview(
                    id: .init(rawValue: "\(macID)-workspace-\(workspaceIndex)"),
                    macDeviceID: macID,
                    name: "Verifier \(letter) Workspace \(workspaceIndex)",
                    terminals: [
                        MobileTerminalPreview(
                            id: .init(rawValue: "\(macID)-terminal-\(workspaceIndex)"),
                            name: "Terminal \(workspaceIndex)"
                        ),
                    ]
                )
            }
            return (macID, MacWorkspaceState(
                macDeviceID: macID,
                displayName: "Verifier Mac \(letter)",
                workspaces: workspaces,
                status: .connected
            ))
        })
    }

    private func statusName(_ status: MobileMacConnectionStatus) -> String {
        switch status {
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .unavailable: "unavailable"
        }
    }

    private func evidenceURL() throws -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches.appendingPathComponent(evidenceFileName)
    }

}

private extension JSONEncoder {
    static var prettyVerifierEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Array {
    func chunkedForVerifier(pageSize: Int) -> [[Element]] {
        guard pageSize > 0 else { return [self] }
        return stride(from: 0, to: count, by: pageSize).map {
            Array(self[$0..<Swift.min($0 + pageSize, count)])
        }
    }
}

#endif
