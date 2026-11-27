import Foundation
import Testing
@testable import CmuxMobileModel

/// Saving the Mac's sizing policy from the phone (review findings 4 and 5
/// on PR #24650): every token the phone sends is one the Mac accepts, and
/// quick changes reach the Mac one at a time, the newest last, so a slow or
/// failed earlier save never wins over a later choice.
@MainActor @Suite struct HostSizePolicyModelTests {
    /// A Mac whose answers the test releases one at a time.
    @MainActor final class SlowMac: TerminalSizingService {
        var thisDeviceID: String? { "ios-1" }
        var stored = HostSizePolicy()
        /// Each `setHostPolicy` waits here until the test resumes it.
        var waiting: [(HostSizePolicy, CheckedContinuation<Void, any Error>)] = []
        var sent: [HostSizePolicy] = []
        var loads = 0
        /// While set, each `hostPolicy` reads the Mac's policy, then waits
        /// here before it answers (a slow reload).
        var holdsLoads = false
        var waitingLoads: [CheckedContinuation<Void, Never>] = []

        func hostPolicy(macID: String, surface: Int?) async throws -> HostSizePolicyInfo {
            loads += 1
            let read = stored
            if holdsLoads { await withCheckedContinuation { waitingLoads.append($0) } }
            return HostSizePolicyInfo(policy: read)
        }

        func setHostPolicy(macID: String, policy: HostSizePolicy) async throws -> HostSizePolicy {
            sent.append(policy)
            try await withCheckedThrowingContinuation { waiting.append((policy, $0)) }
            stored = policy
            return policy
        }

        func answer(failing: Bool = false) {
            let (_, continuation) = waiting.removeFirst()
            if failing {
                continuation.resume(throwing: URLError(.timedOut))
            } else {
                continuation.resume()
            }
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func quickChangesReachTheMacInOrderAndTheNewestWins() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        let first = HostSizePolicy(mode: .mac)
        let second = HostSizePolicy(mode: .latest)
        Task { await model.save(first) }
        await settle()
        Task { await model.save(second) }
        await settle()
        // One save at a time: the second waits for the first.
        #expect(mac.sent == [first])
        #expect(model.info?.policy == second)
        mac.answer()
        await settle()
        #expect(mac.sent == [first, second])
        #expect(model.info?.policy == second)
        mac.answer()
        await settle()
        #expect(mac.stored == second)
        #expect(model.info?.policy == second)
        #expect(model.saving == false)
    }

    @Test func aFailedOlderSaveDoesNotUndoANewerChoice() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        let first = HostSizePolicy(mode: .mac)
        let second = HostSizePolicy(mode: .latest)
        Task { await model.save(first) }
        await settle()
        Task { await model.save(second) }
        await settle()
        mac.answer(failing: true)
        await settle()
        #expect(model.info?.policy == second)
        mac.answer()
        await settle()
        #expect(mac.stored == second)
        #expect(model.info?.policy == second)
        #expect(model.saveError == nil)
    }

    @Test func aFailedNewestSaveShowsTheMacsPolicyAgain() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        Task { await model.save(HostSizePolicy(mode: .mac)) }
        await settle()
        mac.answer(failing: true)
        await settle()
        #expect(model.info?.policy == HostSizePolicy())
        #expect(model.saveError != nil)
    }

    @Test func aReloadWhileSavingKeepsTheShownChoice() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        Task { await model.save(HostSizePolicy(mode: .mac)) }
        await settle()
        await model.reload()
        #expect(model.info?.policy == HostSizePolicy(mode: .mac))
        mac.answer()
        await settle()
    }

    /// Review 2 finding 2: a reload that read the Mac before a save and
    /// answers after it ends never puts the older policy back on screen.
    @Test func aReloadOlderThanASaveDoesNotShowTheOldPolicy() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        mac.holdsLoads = true
        Task { await model.reload() }
        await settle()
        Task { await model.save(HostSizePolicy(mode: .mac)) }
        await settle()
        mac.answer()
        await settle()
        #expect(model.saving == false)
        mac.waitingLoads.removeFirst().resume()
        await settle()
        #expect(model.info?.policy == HostSizePolicy(mode: .mac))
    }

    /// A refusal from a Mac whose cmux lets no phone change the policy
    /// reads as that, not as the daemon's error text.
    @Test func aMacThatRefusesPhonesSaysSo() async {
        let mac = SlowMac()
        let model = HostSizePolicyModel(macID: "m", service: mac)
        await model.reload()
        Task { await model.save(HostSizePolicy(mode: .mac)) }
        await settle()
        let (_, continuation) = mac.waiting.removeFirst()
        continuation.resume(throwing: HostSizePolicyError.refused("forbidden: set-host-size-policy needs the cmux app or a phone lane"))
        await settle()
        #expect(model.saveError == HostSizePolicyModel.phoneRefusedMessage)
    }

    @Test func thePriorityOrderHoldsOnlyTokensTheMacAccepts() throws {
        var participants: [[String: Any]] = [
            ["id": "c1", "device_kind": "mac", "viewport": ["cols": 120, "rows": 39], "counts": true],
            ["id": "c2", "device_kind": "iphone", "device_id": "has space", "viewport": NSNull(), "counts": false],
            ["id": "c3", "device_kind": "tui", "device_id": "host/name", "viewport": NSNull(), "counts": false],
            ["id": "c4", "device_kind": "iphone", "device_id": String(repeating: "x", count: 129), "viewport": NSNull(), "counts": false],
        ]
        for index in 0..<40 {
            participants.append(["id": "p\(index)", "device_kind": "iphone", "device_id": "phone-\(index)", "viewport": NSNull(), "counts": false])
        }
        let wire: [String: Any] = [
            "generation": 1, "cols": 120, "rows": 39, "reason": "smallest", "owners": ["c1"],
            "policy": ["mode": "smallest", "priority": [], "fixed": NSNull()], "participants": participants,
        ]
        let state = try #require(TerminalSizeState.decode(wire))
        let presentation = TerminalSizingPresentation(state: state, selfParticipant: nil, macParticipants: ["c1"], thisDeviceID: "ios-1")
        let tokens = presentation.orderRows(["device:bad token", "mac"]).map(\.token)
        #expect(tokens.count == HostSizePolicy.maxOrder)
        #expect(tokens.allSatisfy(HostSizePolicy.isValidToken))
        #expect(tokens.prefix(2) == ["mac", "device:ios-1"])
        #expect(!tokens.contains("device:has space"))
        #expect(!tokens.contains("device:host/name"))
    }
}
