import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A completed warm stands in for the guest reads, including when it completes during start.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudWarmReceiptTests {
    @Test func receiptAfterRegistrationAndCopySkipsTheMachineReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("receipt-cli"), marker = directory.appendingPathComponent("copied")
        // The existing CLI transport is real; this guest-free fixture publishes its receipt only at wait-copy.
        try """
        #!/bin/sh
        case "$*" in
          *waitCopy*) touch '\(marker.path)'; echo '{"ok":true,"waited":true}' ;;
          *loginReceipt*) test -f '\(marker.path)' || exit 1; echo '{"ok":true,"installed":true}' ;;
          *) exit 1 ;;
        esac
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let claims = CloudClaimedCopyRegistrations(), gate = CloudClaimedCopyOrderTests.Gate()
        let platform = try #require(URL(string: "https://staging.example"))
        let machine = "vm_0123456789abcdefghij"
        let registration = claims.register(machine) { await gate.wait(); return true }
        let start = Task { @MainActor in
            var decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: "claude", signedIn: true)
            var machineReads = 0
            let ready = await decision.takeWarmReceipt(cli: binary, machine: machine, userID: "user_a", ask: .init(), claims: claims) {
                #expect(FileManager.default.fileExists(atPath: marker.path))
                return .init(platform: platform, team: "team_a", install: "inst_a", credential: "digest")
            }
            if !ready {
                decision.callerOwns = true
                try await decision.readMachine(exec: { _ in "vm-kind:owner\n" }, pause: {}, login: { (nil, false) })
                machineReads += 1
            }
            #expect(ready && machineReads == 0 && decision.outcome == CloudHarnessLoginDecision.warmReceipt)
            #expect(decision.guestStdout == nil && decision.machineProbe == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        gate.open()
        #expect(await registration.value)
        try await start.value
    }

    @Test func explicitLoginChoiceNeverUsesTheWarmReceipt() async {
        var decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: "claude", signedIn: true)
        let ready = await decision.takeWarmReceipt(cli: URL(fileURLWithPath: "/unused"), machine: "vm_0123456789abcdefghij",
                                                   userID: "user_a", ask: .init(requested: .some(.none)), claims: .init()) {
            Issue.record("an explicit login choice must not read receipt scope")
            return nil
        }
        #expect(!ready)
    }
}
