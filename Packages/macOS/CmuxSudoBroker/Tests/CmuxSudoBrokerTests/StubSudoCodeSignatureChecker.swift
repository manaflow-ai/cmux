@testable import CmuxSudoBroker
import Foundation

/// Stands in for Security.framework bundle validation in unit tests.
final class StubSudoCodeSignatureChecker: SudoCodeSignatureChecking, @unchecked Sendable {
    struct Call: Equatable {
        let bundleURL: URL
        let requirement: SudoCodeSigningRequirement?
        let resourcePath: String
    }

    private let lock = NSLock()
    private let result: Result<Data, SudoCodeSignatureError>
    private var recordedCalls: [Call] = []

    init(digest: Data) {
        result = .success(digest)
    }

    init(failure: SudoCodeSignatureError) {
        result = .failure(failure)
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func sealedResourceDigest(
        bundleURL: URL,
        requirement: SudoCodeSigningRequirement?,
        resourcePath: String
    ) throws -> Data {
        lock.withLock {
            recordedCalls.append(
                Call(bundleURL: bundleURL, requirement: requirement, resourcePath: resourcePath)
            )
        }
        return try result.get()
    }
}

extension SudoBundledHelperPolicy {
    static func testPolicy(
        appBundleURL: URL = URL(fileURLWithPath: "/Applications/cmux.app")
    ) -> SudoBundledHelperPolicy {
        SudoBundledHelperPolicy.developerID(
            appBundleURL: appBundleURL,
            teamIdentifier: "7WLXT3NR37"
        )!
    }
}

/// Returns a fixed helper without touching the filesystem, for tests that reach spawning.
struct StaticSudoHelperResolver: SudoBundledHelperResolving {
    var helper = SudoVerifiedHelper(
        sourceURL: URL(fileURLWithPath: "/usr/bin/false"),
        sha256: String(repeating: "0", count: 64),
        requirement: nil,
        interpreter: nil
    )

    func privilegedExecutor() throws -> SudoVerifiedHelper { helper }
    func touchIDSetupScript() throws -> SudoVerifiedHelper { helper }
}
