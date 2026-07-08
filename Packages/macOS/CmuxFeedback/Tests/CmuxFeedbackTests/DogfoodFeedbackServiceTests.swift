import Foundation
import Testing

@testable import CmuxFeedback

@Suite("DogfoodFeedbackService")
struct DogfoodFeedbackServiceTests {
    private func makeService(
        limits: DogfoodFeedbackLimits = .default,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
    ) -> (DogfoodFeedbackService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dogfood-test-\(UUID().uuidString)", isDirectory: true)
        let service = DogfoodFeedbackService(limits: limits, cacheRoot: root, now: now)
        return (service, root)
    }

    @Test("privileged domain gate trims, lowercases, and matches the suffix")
    func privilegeGate() {
        #expect(DogfoodFeedbackService.isPrivilegedFeedbackEmail("a@manaflow.ai"))
        #expect(DogfoodFeedbackService.isPrivilegedFeedbackEmail("  A@Manaflow.AI \n"))
        #expect(!DogfoodFeedbackService.isPrivilegedFeedbackEmail("a@example.com"))
        #expect(!DogfoodFeedbackService.isPrivilegedFeedbackEmail(nil))
        #expect(!DogfoodFeedbackService.isPrivilegedFeedbackEmail("manaflow.ai@evil.com"))
    }

    @Test("non-privileged caller is rejected before any I/O")
    func unauthorized() async throws {
        let (service, root) = makeService()
        let outcome = await service.submit(
            DogfoodFeedbackSubmission(text: "hi", terminalText: "", buildStamp: "", diagnosticBlobBase64: ""),
            authenticatedEmail: "nope@example.com"
        )
        #expect(outcome == .unauthorized)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("oversized base64 string is rejected without decoding")
    func base64CharCapRejected() async throws {
        let limits = DogfoodFeedbackLimits(
            maxTextChars: 16, maxTerminalChars: 16, maxBuildStampChars: 16,
            maxBlobBase64Chars: 4, maxBlobBytes: 1024, maxRetainedBundles: 5
        )
        let (service, _) = makeService(limits: limits)
        let outcome = await service.submit(
            DogfoodFeedbackSubmission(text: "", terminalText: "", buildStamp: "", diagnosticBlobBase64: "AAAAAAAA"),
            authenticatedEmail: "a@manaflow.ai"
        )
        #expect(outcome == .invalidParams(reason: "diagnostic_blob_base64 exceeds size limit"))
    }

    @Test("decoded blob over the byte cap is dropped")
    func blobByteCapRejected() async throws {
        let limits = DogfoodFeedbackLimits(
            maxTextChars: 16, maxTerminalChars: 16, maxBuildStampChars: 16,
            maxBlobBase64Chars: 1_000_000, maxBlobBytes: 4, maxRetainedBundles: 5
        )
        let (service, _) = makeService(limits: limits)
        let blob = Data(repeating: 0xAB, count: 32).base64EncodedString()
        let outcome = await service.submit(
            DogfoodFeedbackSubmission(text: "", terminalText: "", buildStamp: "", diagnosticBlobBase64: blob),
            authenticatedEmail: "a@manaflow.ai"
        )
        #expect(outcome == .invalidParams(reason: "diagnostic blob exceeds size limit"))
    }

    @Test("a valid submission writes a bundle with a manifest and decoded log")
    func writesBundle() async throws {
        let (service, root) = makeService()
        let payload = Data("hello-diagnostic".utf8)
        let outcome = await service.submit(
            DogfoodFeedbackSubmission(
                text: "bug report",
                terminalText: "$ echo hi",
                buildStamp: "DEV abc",
                diagnosticBlobBase64: payload.base64EncodedString()
            ),
            authenticatedEmail: "dev@manaflow.ai"
        )
        guard case let .written(bundlePath, bytes) = outcome else {
            Issue.record("expected written, got \(outcome)")
            return
        }
        #expect(bytes == payload.count)
        let bundleDir = URL(fileURLWithPath: bundlePath)
        let logURL = bundleDir.appendingPathComponent("diagnostic.log")
        let manifestURL = bundleDir.appendingPathComponent("bundle.json")
        #expect(try Data(contentsOf: logURL) == payload)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        #expect(manifest?["schema"] as? String == "cmux.dogfood.feedback.v1")
        #expect(manifest?["text"] as? String == "bug report")
        #expect(manifest?["terminal_text"] as? String == "$ echo hi")
        #expect(manifest?["build_stamp"] as? String == "DEV abc")
        #expect(manifest?["diagnostic_log_file"] as? String == "diagnostic.log")
        #expect(manifest?["diagnostic_log_bytes"] as? Int == payload.count)
        // Owner-only permissions on the bundle directory and files.
        let dirPerms = try FileManager.default.attributesOfItem(atPath: bundleDir.path)[.posixPermissions] as? Int
        let logPerms = try FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
        #expect(logPerms == 0o600)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("text fields are capped before persisting")
    func capsFields() async throws {
        let limits = DogfoodFeedbackLimits(
            maxTextChars: 3, maxTerminalChars: 2, maxBuildStampChars: 1,
            maxBlobBase64Chars: 1_000_000, maxBlobBytes: 1_000_000, maxRetainedBundles: 5
        )
        let (service, root) = makeService(limits: limits)
        let outcome = await service.submit(
            DogfoodFeedbackSubmission(
                text: "abcdef",
                terminalText: "xyz",
                buildStamp: "ZZZ",
                diagnosticBlobBase64: Data("d".utf8).base64EncodedString()
            ),
            authenticatedEmail: "dev@manaflow.ai"
        )
        guard case let .written(bundlePath, _) = outcome else {
            Issue.record("expected written, got \(outcome)")
            return
        }
        let manifestURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("bundle.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        #expect(manifest?["text"] as? String == "abc")
        #expect(manifest?["terminal_text"] as? String == "xy")
        #expect(manifest?["build_stamp"] as? String == "Z")
        try? FileManager.default.removeItem(at: root)
    }

    @Test("pruning keeps only the newest N bundle directories")
    func prunesOldBundles() async throws {
        let limits = DogfoodFeedbackLimits(
            maxTextChars: 16, maxTerminalChars: 16, maxBuildStampChars: 16,
            maxBlobBase64Chars: 1_000_000, maxBlobBytes: 1_000_000, maxRetainedBundles: 2
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dogfood-prune-\(UUID().uuidString)", isDirectory: true)
        // Distinct, monotonically increasing timestamps so the lexicographic
        // sort is chronological and deterministic across writes.
        var tick = 1_700_000_000.0
        let payload = Data("x".utf8).base64EncodedString()
        for _ in 0..<5 {
            let captured = tick
            let service = DogfoodFeedbackService(
                limits: limits,
                cacheRoot: root,
                now: { Date(timeIntervalSince1970: captured) }
            )
            _ = await service.submit(
                DogfoodFeedbackSubmission(text: "", terminalText: "", buildStamp: "", diagnosticBlobBase64: payload),
                authenticatedEmail: "dev@manaflow.ai"
            )
            tick += 60
        }
        let remaining = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(remaining.count == 2)
        try? FileManager.default.removeItem(at: root)
    }
}
