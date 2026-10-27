/// One generated JSON object for a decoder under test, built field by field together with its
/// oracle: each field holds what the decoder must read, or (as the test draws) is missing or of
/// another type. ``complete`` turns false once a field the decoder cannot do without is missing
/// or mistyped, so the test knows whether the object must decode.
public struct FuzzRecord: Sendable, Equatable {
    public var fields: [String: FuzzJSON] = [:]
    /// False once a required field (or a strict optional one given a wrong type) is unusable.
    public var complete = true

    public init() {}

    /// The object.
    public var json: FuzzJSON { .object(fields) }

    /// A field the decoder needs: `value`, or one time in `odds` missing or of another JSON type.
    public mutating func require(_ key: String, _ value: FuzzJSON, _ rng: inout FuzzRNG, odds: Int = 12) {
        guard rng.oneIn(odds) else {
            fields[key] = value
            return
        }
        complete = false
        if rng.bool() { fields[key] = FuzzJSON.random(&rng, notOf: [value.kind]) }
    }

    /// A field the decoder reads leniently: `value` (kept as `decoded`), missing, or a value of the
    /// `wrong` kinds, which the decoder must skip (`otherwise`).
    public mutating func lenient<T>(
        _ key: String, _ value: FuzzJSON, decoded: T, otherwise: T, wrong: [FuzzJSON.Kind], _ rng: inout FuzzRNG
    ) -> T {
        switch rng.below(3) {
        case 0:
            fields[key] = value
            return decoded
        case 1:
            return otherwise
        default:
            fields[key] = FuzzJSON.random(&rng, of: wrong)
            return otherwise
        }
    }

    /// An optional field of a strict decoder (a synthesized `Decodable`): `value` (kept as `decoded`),
    /// missing or null (nil); with `wrongOdds`, one time in that many of another type, which makes
    /// the whole object unusable.
    public mutating func optional<T>(
        _ key: String, _ value: FuzzJSON, decoded: T, _ rng: inout FuzzRNG, wrongOdds: Int? = nil
    ) -> T? {
        if let wrongOdds, rng.oneIn(wrongOdds) {
            fields[key] = FuzzJSON.random(&rng, notOf: [value.kind, .null])
            complete = false
            return nil
        }
        switch rng.below(3) {
        case 0:
            fields[key] = value
            return decoded
        case 1:
            return nil
        default:
            fields[key] = .null
            return nil
        }
    }

    /// Up to two fields whose keys start with `x`, which no decoder under test reads.
    public mutating func noise(_ rng: inout FuzzRNG) {
        for _ in 0..<rng.below(3) { fields["x" + rng.text(["a", "b", "_"], 5)] = FuzzJSON.random(&rng) }
    }
}
