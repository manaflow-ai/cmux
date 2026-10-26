// Compile-fail fixture of the BlockingPermit (plans/cmux-next/chrome-parity/p02-threads.md, task 111). Not in any
// target: scripts/cmux-next/check-blocking-permit-fixture.sh type-checks it against a built CmuxNextCompat and
// expects the diagnostic of every `// expect:` line in its output.
import CmuxNextCompat
import Foundation

// expect: is unavailable from asynchronous contexts
func readInAsyncCode(_ url: URL, _ permit: borrowing BlockingPermit) async throws -> Data {
    try Data(blockingContentsOf: url, permit)
}

// expect: is deprecated: Pass the BlockingPermit
func statWithoutAPermit(_ url: URL) -> Bool {
    FileManager.checked.fileExists(atPath: url.path)
}

// expect: inaccessible due to 'package' protection level
func makeAPermitOutsideThePackage() -> BlockingPermit.Issuer {
    let permit = BlockingPermit(issuer: .lane)
    return permit.issuer
}
