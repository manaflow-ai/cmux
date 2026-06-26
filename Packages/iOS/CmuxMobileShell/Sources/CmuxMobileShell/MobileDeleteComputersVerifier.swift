#if DEBUG
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

public struct MobileDeleteComputersVerificationWorkspace: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var macDeviceID: String?
    public var status: String?
}

public struct MobileDeleteComputersVerificationCheckpoint: Codable, Equatable, Sendable {
    public var name: String
    public var workspaceCount: Int
    public var workspaceIDs: [String]
    public var workspaceMacIDs: [String]
    public var displayMacIDs: [String]
    public var workspaceListStatus: String
    public var pages: [[MobileDeleteComputersVerificationWorkspace]]
}

public struct MobileDeleteComputersVerificationResult: Codable, Equatable, Sendable {
    public var passed: Bool
    public var reason: String
    public var deletedHalfMacIDs: [String]
    public var deletedAllMacIDs: [String]
    public var halfRemovedAbsent: Bool
    public var halfRemainingPresent: Bool
    public var halfNoDisconnectedBanner: Bool
    public var refreshPreservedHalfList: Bool
    public var allRemoved: Bool
    public var refreshPreservedEmptyList: Bool
    public var checkpoints: [MobileDeleteComputersVerificationCheckpoint]
    public var evidencePath: String?
}

@MainActor
public enum MobileDeleteComputersVerifier {
    public static let environmentKey = "CMUX_DELETE_COMPUTERS_VERIFIER"
    public static let evidenceFileName = "cmux-delete-computers-verification.json"

    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    public static func runAndPersist() async -> MobileDeleteComputersVerificationResult {
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

    private static func run() async -> MobileDeleteComputersVerificationResult {
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

    private static func runScenario() async throws -> MobileDeleteComputersVerificationResult {
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

    private static func checkpoint(
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

    private static func seededMacs(userID: String, teamID: String) -> [MobilePairedMac] {
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

    private static func seededWorkspaceStates() -> [String: MacWorkspaceState] {
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

    private static func statusName(_ status: MobileMacConnectionStatus) -> String {
        switch status {
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .unavailable: "unavailable"
        }
    }

    private static func evidenceURL() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
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

@MainActor
private final class DeleteComputersVerifierIdentityProvider: MobileIdentityProviding {
    let currentUserID: String?

    init(userID: String?) {
        currentUserID = userID
    }
}

private actor DeleteComputersVerifierPairedMacStore: MobilePairedMacStoring {
    private var records: [MobilePairedMac]

    init(records: [MobilePairedMac]) {
        self.records = records
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        if markActive {
            records = records.map { mac in
                var copy = mac
                copy.isActive = false
                return copy
            }
        }
        if let index = records.firstIndex(where: { $0.macDeviceID == macDeviceID }) {
            records[index].displayName = displayName
            records[index].routes = routes
            records[index].lastSeenAt = now
            records[index].isActive = markActive
            records[index].stackUserID = stackUserID
            records[index].teamID = teamID
        } else {
            records.append(MobilePairedMac(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                createdAt: now,
                lastSeenAt: now,
                isActive: markActive,
                stackUserID: stackUserID,
                teamID: teamID
            ))
        }
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        records.filter { mac in
            mac.stackUserID == stackUserID && mac.teamID == teamID
        }
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        records.first { mac in
            mac.isActive && mac.stackUserID == stackUserID && mac.teamID == teamID
        }
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            if copy.stackUserID == stackUserID && copy.teamID == teamID {
                copy.isActive = copy.macDeviceID == macDeviceID
            }
            return copy
        }
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        records = records.map { mac in
            var copy = mac
            if copy.stackUserID == stackUserID && copy.teamID == teamID {
                copy.isActive = false
            }
            return copy
        }
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard let index = records.firstIndex(where: {
            $0.macDeviceID == macDeviceID && $0.stackUserID == stackUserID && $0.teamID == teamID
        }) else { return }
        records[index].customName = customName
        records[index].customColor = customColor
        records[index].customIcon = customIcon
        records[index].lastSeenAt = now
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        records.removeAll {
            $0.macDeviceID == macDeviceID && $0.stackUserID == stackUserID && $0.teamID == teamID
        }
    }

    func removeAll() async throws {
        records.removeAll()
    }
}
#endif
