import Foundation
@testable import CmuxGit

/// A reftable `HEAD` reader that records every call and the signatures it saw,
/// optionally delegating to a real reader.
final class CountingGitReftableHeadReader: GitReftableHeadReading, @unchecked Sendable {
    private let base: (any GitReftableHeadReading)?
    private let lock = NSLock()
    private var observedStackSignatures: [String] = []

    init(base: (any GitReftableHeadReading)? = nil) {
        self.base = base
    }

    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        lock.lock()
        observedStackSignatures.append(stackSignature)
        lock.unlock()
        return base?.head(workTreeRoot: workTreeRoot, stackSignature: stackSignature)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedStackSignatures.count
    }

    var distinctStackSignatureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(observedStackSignatures).count
    }
}
