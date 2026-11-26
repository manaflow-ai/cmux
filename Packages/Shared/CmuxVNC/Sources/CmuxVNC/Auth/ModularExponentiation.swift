import Foundation

/// `base ^ exponent mod modulus` over big-endian byte strings, for Apple
/// Diffie-Hellman (VNC security type 30, 1024-bit and larger primes).
/// Montgomery multiplication (CIOS, 32-bit limbs); the modulus must be odd,
/// which every DH prime is.
struct ModularExponentiation {
    /// Little-endian 32-bit limbs of the modulus.
    private let modulus: [UInt32]
    private let limbCount: Int
    /// -modulus^-1 mod 2^32.
    private let nPrime: UInt32
    /// R^2 mod modulus, R = 2^(32 * limbCount).
    private let rSquared: [UInt32]
    private let byteCount: Int

    /// Nil when the modulus is zero or even.
    init?(modulus bytes: [UInt8]) {
        let limbs = Self.limbs(bytes)
        guard let low = limbs.first, low & 1 == 1 else { return nil }
        modulus = limbs
        limbCount = limbs.count
        byteCount = bytes.count
        var inverse = low
        for _ in 0 ..< 5 { inverse = inverse &* (2 &- low &* inverse) }
        nPrime = 0 &- inverse
        // R^2 mod m by doubling 1 a total of 2 * 32 * n times.
        var value = [UInt32](repeating: 0, count: limbs.count)
        value[0] = 1
        for _ in 0 ..< (64 * limbs.count) { Self.doubleMod(&value, limbs) }
        rSquared = value
    }

    /// `base ^ exponent mod modulus`, big-endian, padded to the modulus length.
    func power(_ base: [UInt8], _ exponent: [UInt8]) -> [UInt8] {
        let one = [UInt32](repeating: 0, count: limbCount).enumerated().map { $0.offset == 0 ? UInt32(1) : 0 }
        let baseMont = multiply(reduce(base), rSquared)
        var accumulator = multiply(one, rSquared)
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                accumulator = multiply(accumulator, accumulator)
                if (byte >> UInt8(bit)) & 1 == 1 { accumulator = multiply(accumulator, baseMont) }
            }
        }
        return Self.bytes(multiply(accumulator, one), count: byteCount)
    }

    /// Any-length big-endian value mod the modulus (bit by bit).
    private func reduce(_ bytes: [UInt8]) -> [UInt32] {
        var value = [UInt32](repeating: 0, count: limbCount)
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                Self.doubleMod(&value, modulus)
                if (byte >> UInt8(bit)) & 1 == 1 { Self.addOneMod(&value, modulus) }
            }
        }
        return value
    }

    /// Montgomery product a * b * R^-1 mod m (inputs below m).
    private func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let n = limbCount
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0 ..< n {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0 ..< n {
                let sum = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                t[j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            var sum = UInt64(t[n]) + carry
            t[n] = UInt32(truncatingIfNeeded: sum)
            t[n + 1] = UInt32(sum >> 32)
            let m = UInt64(t[0] &* nPrime)
            sum = UInt64(t[0]) + m * UInt64(modulus[0])
            carry = sum >> 32
            for j in 1 ..< max(n, 1) {
                sum = UInt64(t[j]) + m * UInt64(modulus[j]) + carry
                t[j - 1] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            sum = UInt64(t[n]) + carry
            t[n - 1] = UInt32(truncatingIfNeeded: sum)
            t[n] = t[n + 1] &+ UInt32(sum >> 32)
            t[n + 1] = 0
        }
        var result = Array(t[0 ..< n])
        if t[n] != 0 || !Self.less(result, modulus) { Self.subtract(&result, modulus) }
        return result
    }

    // MARK: Limb helpers (little-endian)

    static func limbs(_ bytes: [UInt8]) -> [UInt32] {
        var trimmed = bytes.drop { $0 == 0 }
        if trimmed.isEmpty { trimmed = [0] }
        let padded = [UInt8](repeating: 0, count: (4 - trimmed.count % 4) % 4) + trimmed
        var limbs: [UInt32] = []
        var index = padded.count
        while index > 0 {
            limbs.append(UInt32(padded[index - 4]) << 24 | UInt32(padded[index - 3]) << 16
                | UInt32(padded[index - 2]) << 8 | UInt32(padded[index - 1]))
            index -= 4
        }
        return limbs
    }

    static func bytes(_ limbs: [UInt32], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() {
            out.append(contentsOf: [UInt8(limb >> 24), UInt8((limb >> 16) & 0xFF), UInt8((limb >> 8) & 0xFF), UInt8(limb & 0xFF)])
        }
        if out.count > count { return Array(out.suffix(count)) }
        return [UInt8](repeating: 0, count: count - out.count) + out
    }

    static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for index in stride(from: a.count - 1, through: 0, by: -1) where a[index] != b[index] {
            return a[index] < b[index]
        }
        return false
    }

    /// a -= b (wrapping; callers ensure a >= b, or a carried out of the top limb).
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for index in a.indices {
            let difference = UInt64(a[index]) &- UInt64(b[index]) &- borrow
            a[index] = UInt32(truncatingIfNeeded: difference)
            borrow = (difference >> 63) & 1
        }
    }

    /// value = 2 * value mod m (value below m).
    static func doubleMod(_ value: inout [UInt32], _ m: [UInt32]) {
        var carry: UInt32 = 0
        for index in value.indices {
            let next = value[index] >> 31
            value[index] = value[index] << 1 | carry
            carry = next
        }
        if carry != 0 || !less(value, m) { subtract(&value, m) }
    }

    /// value = value + 1 mod m (value below m).
    static func addOneMod(_ value: inout [UInt32], _ m: [UInt32]) {
        var carry: UInt32 = 1
        for index in value.indices where carry != 0 {
            let (sum, overflow) = value[index].addingReportingOverflow(carry)
            value[index] = sum
            carry = overflow ? 1 : 0
        }
        if carry != 0 || !less(value, m) { subtract(&value, m) }
    }
}
