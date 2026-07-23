#if DEBUG
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
public import Foundation

/// DEBUG-only scenario runner used by the iOS UI test to prove computer hiding
/// updates the workspace list and refresh behavior.
@MainActor
public struct MobileHideComputersVerifier {
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
        environmentKey: String = "CMUX_HIDE_COMPUTERS_VERIFIER",
        evidenceFileName: String = "cmux-hide-computers-verification.json"
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

    /// Run the hide-computers scenario and persist JSON evidence to Caches.
    public func runAndPersist() async -> MobileHideComputersVerificationResult {
        var result = await run()
        do {
            let url = try evidenceURL()
            let data = try JSONEncoder.prettyVerifierEncoder.encode(result)
            try data.write(to: url, options: [.atomic])
            result.evidencePath = url.path
            let updatedData = try JSONEncoder.prettyVerifierEncoder.encode(result)
            try updatedData.write(to: url, options: [.atomic])
        } catch {
            result.reason = "\(result.reason); failed to write evidence: \(error)"
        }
        return result
    }

    private func run() async -> MobileHideComputersVerificationResult {
        do {
            return try await runScenario()
        } catch {
            return MobileHideComputersVerificationResult(
                passed: false,
                reason: "Verifier threw \(error)",
                hiddenHalfMacIDs: [],
                hiddenAllMacIDs: [],
                halfHiddenAbsent: false,
                halfRemainingPresent: false,
                halfNoDisconnectedBanner: false,
                refreshPreservedHalfList: false,
                allHidden: false,
                refreshPreservedEmptyList: false,
                checkpoints: [],
                evidencePath: nil
            )
        }
    }

    private func runScenario() async throws -> MobileHideComputersVerificationResult {
        let userID = "hide-computers-verifier-user"
        let teamID = "hide-computers-verifier-team"
        let store = HideComputersVerifierPairedMacStore(records: seededMacs(userID: userID, teamID: teamID))
        let identity = HideComputersVerifierIdentityProvider(userID: userID)
        let defaultsSuiteName = "hide-computers-verifier-\(UUID().uuidString)"
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
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await shell.loadPairedMacs()
        shell.setWorkspaceStatesForTesting(seededWorkspaceStates(), foregroundMacDeviceID: "mac-a")
        let initial = checkpoint("initial", shell: shell)

        let halfHideIDs = ["mac-a", "mac-b"]
        for macID in halfHideIDs {
            await shell.hideMac(macDeviceID: macID)
        }
        let afterHalfHide = checkpoint("after-half-hide", shell: shell)

        await shell.reconnectOrRefresh()
        let afterHalfRefresh = checkpoint("after-half-refresh", shell: shell)

        let remainingHideIDs = ["mac-c", "mac-d"]
        for macID in remainingHideIDs {
            await shell.hideMac(macDeviceID: macID)
        }
        let afterAllHide = checkpoint("after-all-hide", shell: shell)

        await shell.reconnectOrRefresh()
        let afterAllRefresh = checkpoint("after-all-refresh", shell: shell)

        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let hiddenHalf = Set(halfHideIDs)
        let expectedRemaining = Set(["mac-c", "mac-d"])
        let aggregation = MobileWorkspaceAggregation()
        let expectedRemainingWorkspaceIDs = Set(
            seededWorkspaceStates()
                .filter { expectedRemaining.contains($0.key) }
                .flatMap { macID, state in
                    state.workspaces.map {
                        aggregation.rowID(macDeviceID: macID, workspaceID: $0.id).rawValue
                    }
                }
        )
        let halfHiddenAbsent = afterHalfHide.workspaceMacIDs.allSatisfy { !hiddenHalf.contains($0) }
            && afterHalfRefresh.workspaceMacIDs.allSatisfy { !hiddenHalf.contains($0) }
        let halfRemainingPresent = Set(afterHalfHide.workspaceIDs) == expectedRemainingWorkspaceIDs
            && afterHalfHide.workspaceCount == expectedRemainingWorkspaceIDs.count
            && Set(afterHalfRefresh.workspaceIDs) == expectedRemainingWorkspaceIDs
            && afterHalfRefresh.workspaceCount == expectedRemainingWorkspaceIDs.count
        let halfNoDisconnectedBanner = afterHalfHide.workspaceListStatus == "connected"
            && afterHalfRefresh.workspaceListStatus == "connected"
        let refreshPreservedHalfList = afterHalfRefresh.workspaceIDs == afterHalfHide.workspaceIDs
            && afterHalfRefresh.displayMacIDs == afterHalfHide.displayMacIDs
        let allHidden = afterAllHide.workspaceIDs.isEmpty
            && afterAllHide.displayMacIDs.isEmpty
        let refreshPreservedEmptyList = afterAllRefresh.workspaceIDs.isEmpty
            && afterAllRefresh.displayMacIDs.isEmpty
        let passed = halfHiddenAbsent
            && halfRemainingPresent
            && halfNoDisconnectedBanner
            && refreshPreservedHalfList
            && allHidden
            && refreshPreservedEmptyList
        let reason = passed
            ? "PASS"
            : "halfHiddenAbsent=\(halfHiddenAbsent) halfRemainingPresent=\(halfRemainingPresent) halfNoDisconnectedBanner=\(halfNoDisconnectedBanner) refreshPreservedHalfList=\(refreshPreservedHalfList) allHidden=\(allHidden) refreshPreservedEmptyList=\(refreshPreservedEmptyList)"

        return MobileHideComputersVerificationResult(
            passed: passed,
            reason: reason,
            hiddenHalfMacIDs: halfHideIDs,
            hiddenAllMacIDs: halfHideIDs + remainingHideIDs,
            halfHiddenAbsent: halfHiddenAbsent,
            halfRemainingPresent: halfRemainingPresent,
            halfNoDisconnectedBanner: halfNoDisconnectedBanner,
            refreshPreservedHalfList: refreshPreservedHalfList,
            allHidden: allHidden,
            refreshPreservedEmptyList: refreshPreservedEmptyList,
            checkpoints: [initial, afterHalfHide, afterHalfRefresh, afterAllHide, afterAllRefresh],
            evidencePath: nil
        )
    }

    private func checkpoint(
        _ name: String,
        shell: MobileShellComposite
    ) -> MobileHideComputersVerificationCheckpoint {
        let workspaces = shell.workspaces.map { workspace in
            MobileHideComputersVerificationWorkspace(
                id: workspace.id.rawValue,
                name: workspace.name,
                macDeviceID: workspace.macDeviceID,
                status: workspace.macConnectionStatus.map(statusName)
            )
        }
        return MobileHideComputersVerificationCheckpoint(
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
