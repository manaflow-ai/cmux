import Darwin
import Foundation
import Testing

/// `HeapQuiet` rests on `flock` locks of separate opens of one file excluding each other within
/// one process (Darwin): `swift test` runs both measuring targets in one process.
@Suite struct HeapQuietTests {
    @Test func aMeasurementCannotStartWhileAProofHoldsTheLock() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("heap-quiet-test-\(UUID().uuidString).lock")
        defer { unlink(path) }
        let proof = try #require(HeapQuiet.acquire(LOCK_SH | LOCK_NB, at: path))
        let anotherProof = try #require(HeapQuiet.acquire(LOCK_SH | LOCK_NB, at: path), "proofs run side by side")
        #expect(HeapQuiet.acquire(LOCK_EX | LOCK_NB, at: path) == nil, "a measurement waits for the proofs")
        proof.release()
        #expect(HeapQuiet.acquire(LOCK_EX | LOCK_NB, at: path) == nil, "and for the last of them")
        anotherProof.release()
        let measurement = try #require(HeapQuiet.acquire(LOCK_EX | LOCK_NB, at: path))
        #expect(HeapQuiet.acquire(LOCK_SH | LOCK_NB, at: path) == nil, "no proof starts during a measurement")
        measurement.release()
        #expect(HeapQuiet.acquire(LOCK_SH | LOCK_NB, at: path).map { $0.release() } != nil)
    }
}
