import CmuxTerminalBackend
import CmuxTerminalBackendService
import Darwin
import Foundation
import Testing

@Suite("Live backend code-signing verifier", .serialized)
struct SystemBackendPeerTrustVerifierTests {
    @Test("Security.framework validates the exact live audit identity")
    func validatesLiveProcess() throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let signingIdentifier = try codesignIdentifier(executableURL)
        let verifier = SystemBackendPeerTrustVerifier(
            expectedExecutableURL: executableURL,
            expectedSigningIdentifier: signingIdentifier
        )

        let evidence = try verifier.verify(currentPeerIdentity())

        #expect(evidence.signingIdentifier == signingIdentifier)
        #expect(evidence.teamIdentifier == nil)
        #expect(evidence.executableURL.standardizedFileURL == executableURL)
        #expect(evidence.processIDVersion > 0)
    }

    @Test("socket PID must agree with the non-reusable audit identity")
    func rejectsPIDDisagreement() throws {
        let identity = try currentPeerIdentity()
        let mismatched = BackendPeerIdentity(
            processID: identity.processID + 1,
            userID: identity.userID,
            auditToken: identity.auditToken
        )
        let verifier = SystemBackendPeerTrustVerifier(
            expectedExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            expectedSigningIdentifier: try codesignIdentifier(
                URL(fileURLWithPath: CommandLine.arguments[0])
            )
        )

        do {
            _ = try verifier.verify(mismatched)
            Issue.record("expected audit-token PID mismatch")
        } catch let error as BackendPeerTrustError {
            #expect(
                error == .auditTokenProcessMismatch(
                    socket: identity.processID + 1,
                    auditToken: Int32(identity.processID)
                )
            )
        }
    }

    @Test("socket effective UID must agree with the audit identity")
    func rejectsUserDisagreement() throws {
        let identity = try currentPeerIdentity()
        let mismatched = BackendPeerIdentity(
            processID: identity.processID,
            userID: identity.userID + 1,
            auditToken: identity.auditToken
        )
        let verifier = SystemBackendPeerTrustVerifier(
            expectedExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            expectedSigningIdentifier: try codesignIdentifier(
                URL(fileURLWithPath: CommandLine.arguments[0])
            )
        )

        do {
            _ = try verifier.verify(mismatched)
            Issue.record("expected audit-token UID mismatch")
        } catch let error as BackendPeerTrustError {
            #expect(
                error == .auditTokenUserMismatch(
                    socket: identity.userID + 1,
                    auditToken: identity.userID
                )
            )
        }
    }

    @Test("signed identifier mismatch fails closed")
    func rejectsWrongIdentifier() throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let verifier = SystemBackendPeerTrustVerifier(
            expectedExecutableURL: executableURL,
            expectedSigningIdentifier: "invalid.backend.identifier"
        )

        #expect(throws: BackendPeerTrustError.self) {
            _ = try verifier.verify(currentPeerIdentity())
        }
    }

    private func currentPeerIdentity() throws -> BackendPeerIdentity {
        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_AUDIT_TOKEN),
                    words,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw CocoaError(.fileReadUnknown)
        }
        return BackendPeerIdentity(
            processID: UInt32(getpid()),
            userID: UInt32(geteuid()),
            auditToken: BackendAuditToken(
                word0: token.val.0,
                word1: token.val.1,
                word2: token.val.2,
                word3: token.val.3,
                word4: token.val.4,
                word5: token.val.5,
                word6: token.val.6,
                word7: token.val.7
            )
        )
    }

    private func codesignIdentifier(_ executableURL: URL) throws -> String {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", executableURL.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0,
              let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Identifier=") })
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(line.dropFirst("Identifier=".count))
    }
}
