import CmuxNextBrowserImport
import Testing

/// `SecretBytes` keeps its count and the reads in progress behind one lock (no
/// `@unchecked Sendable`): `zero()` empties the bytes at once for new reads and zeroes the memory only
/// once no read is running. Run under TSan too.
@Suite struct SecretBytesTests {
    @Test func zeroDuringAReadLeavesThatReadItsBytesAndZeroesThemWhenItEnds() throws {
        let password = Array("hunter2".utf8)
        let secret = SecretBytes(copying: password)
        let (seen, countAfterZero, base) = secret.withUnsafeBytes { bytes in
            secret.zero()
            return (Array(bytes), secret.count, bytes.baseAddress)
        }

        #expect(seen == password, "a running read never sees half-zeroed bytes")
        #expect(countAfterZero == 0, "empty at once for every new read")
        #expect(secret.isEmpty)
        #expect(secret.withUnsafeBytes { $0.count } == 0)
        // The allocation lives as long as `secret`: its memory is zeroed now that the read has ended.
        let memory = try #require(base)
        let after = withExtendedLifetime(secret) { Array(UnsafeRawBufferPointer(start: memory, count: password.count)) }
        #expect(after == [UInt8](repeating: 0, count: password.count))
    }

    @Test func aSecretMatchesItselfAndNotAnotherOfTheSameLength() {
        let secret = SecretBytes(copying: Array("hunter2".utf8))
        #expect(secret.matches(secret), "two reads of one secret at once")
        #expect(!secret.matches(SecretBytes(copying: Array("hunter3".utf8))))
    }

    @Test(.timeLimit(.minutes(1)))
    func readsOnOtherThreadsSeeEveryByteOrNoneWhileAnotherZeroes() async {
        for _ in 0..<50 {
            let secret = SecretBytes(copying: [UInt8](repeating: 7, count: 64))
            let whole = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask { secret.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 7 } } }
                }
                group.addTask {
                    secret.zero()
                    return true
                }
                var all = true
                for await read in group { all = all && read }
                return all
            }
            #expect(whole)
            #expect(secret.isEmpty)
        }
    }
}
