import Foundation

/// The one random source of the seeded property tests: xorshift64 (13, 7, 17). The
/// algorithm is pinned (a test checks it against a reference), so a replay line
/// printed today replays on a later version of this package.
///
/// It has two modes. Seeded, it is a plain generator: the same seed gives the same
/// choices. `FuzzRun` seeds one per iteration (`derivedSeed`), so the suites keep
/// their seeds and iteration counts but explore other inputs than their old private
/// generators, which drew every iteration from one stream. Replaying bytes, each choice reads
/// the next bytes of the input (eight for `next()`, as few as the range needs for
/// `below(_:)`, little endian), as LLVM's `FuzzedDataProvider`
/// (compiler-rt/include/fuzzer/FuzzedDataProvider.h) does; a coverage-guided fuzzer
/// then drives the same test body through each suite's `oneInput(_:)`.
/// Once the input is used up, the bounded draws (`below`,
/// `byte`, `bytes`, `text`, `int(in:)`) give 0 or empty, so loops sized by a draw
/// end, and `next()` goes on with a fixed xorshift stream: the standard library's
/// `random(in:using:)` rejects some values and draws again, and a generator that
/// gave 0 forever would never let it finish.
public struct FuzzRNG: RandomNumberGenerator, Sendable {
    /// xorshift stays at zero forever from a zero state; seed 0 starts here instead.
    private static let zeroSeedReplacement: UInt64 = 0x9E37_79B9_7F4A_7C15

    private var state: UInt64
    private let tape: [UInt8]?
    private var cursor = 0

    /// A seeded generator. Seed 0 is allowed and replaced by a fixed nonzero state.
    public init(seed: UInt64) {
        state = seed == 0 ? Self.zeroSeedReplacement : seed
        tape = nil
    }

    /// A generator whose choices are the bytes of `input`.
    public init(replaying input: Data) {
        state = Self.zeroSeedReplacement
        tape = [UInt8](input)
    }

    /// The seed of stream `stream` of `seed` (splitmix64 of the pair). `FuzzRun` gives
    /// iteration `i` stream `i`, in default and long mode alike, so iterations draw
    /// unrelated choices and any one of them can be rebuilt from the seed alone.
    public static func derivedSeed(_ seed: UInt64, stream: UInt64) -> UInt64 {
        var z = seed &+ (stream &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Whether a replaying generator has used all of its input (a seeded one never has).
    public var isExhausted: Bool {
        guard let tape else { return false }
        return cursor >= tape.count
    }

    public mutating func next() -> UInt64 {
        if !isExhausted, tape != nil { return take(8) }
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// A value in `0..<n`; 0 when `n` is 0 or negative. Replaying, it reads only the bytes the range
    /// needs (one for `n <= 256`), as `FuzzedDataProvider::ConsumeIntegralInRange` does.
    public mutating func below(_ n: Int) -> Int {
        Int(draw(below: UInt64(max(n, 1))))
    }

    /// True about once in `n` draws.
    public mutating func oneIn(_ n: Int) -> Bool {
        below(n) == 0
    }

    /// True or false, one byte's low bit.
    public mutating func bool() -> Bool {
        byte() & 1 == 1
    }

    /// A value in `range`; its lower bound once a replayed input is used up.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(bitPattern: Int64(range.upperBound &- range.lowerBound))
        let offset = span == .max ? next() : draw(below: span + 1)
        return range.lowerBound &+ Int(truncatingIfNeeded: offset)
    }

    /// A finite value in `range`, from 16 bits of choice (`range.lowerBound` once a replayed
    /// input is used up).
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        let fraction = Double(below(1 << 16)) / Double((1 << 16) - 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * fraction
    }

    public mutating func byte() -> UInt8 {
        tape == nil ? UInt8(truncatingIfNeeded: next()) : UInt8(truncatingIfNeeded: take(1))
    }

    /// Between 0 and `limit - 1` random bytes.
    public mutating func bytes(_ limit: Int) -> Data {
        let count = below(limit)
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(byte()) }
        return out
    }

    /// Exactly `count` random bytes (zeros once a replayed input is used up).
    public mutating func bytes(count: Int) -> [UInt8] {
        (0..<max(count, 0)).map { _ in byte() }
    }

    /// A UUID from 16 drawn bytes, so a body that needs identifiers stays a function of its choices.
    public mutating func uuid() -> UUID {
        let b = bytes(count: 16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Between 0 and `limit - 1` characters drawn from `alphabet`.
    public mutating func text(_ alphabet: [Character], _ limit: Int) -> String {
        guard !alphabet.isEmpty else { return "" }
        var out = ""
        for _ in 0..<below(limit) { out.append(alphabet[below(alphabet.count)]) }
        return out
    }

    /// One element of `choices`, or nil when it is empty.
    public mutating func element<Element>(of choices: [Element]) -> Element? {
        choices.isEmpty ? nil : choices[below(choices.count)]
    }

    /// A value in `0..<bound` (`bound` > 0). Replaying, it reads only the bytes the bound needs.
    private mutating func draw(below bound: UInt64) -> UInt64 {
        guard tape != nil else { return next() % bound }
        var width = 0
        var rest = bound - 1
        while rest > 0 {
            width += 1
            rest >>= 8
        }
        return take(width) % bound
    }

    /// The next `count` (0 to 8) bytes of the tape, little endian; missing bytes read as 0.
    private mutating func take(_ count: Int) -> UInt64 {
        guard let tape else { return 0 }
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<min(count, 8) where cursor < tape.count {
            value |= UInt64(tape[cursor]) << shift
            cursor += 1
            shift += 8
        }
        return value
    }
}
