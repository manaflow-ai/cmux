/// Why a record or a byte stream was refused (names as in fixtures/binary.json).
public enum RecordErrorReason: String, Hashable, Sendable {
    case truncated
    case reservedFlags = "reserved_flags"
    case badCredit = "bad_credit"
    case badJSON = "bad_json"
    case badSeq = "bad_seq"
    case tooLarge = "too_large"
    case badLength = "bad_length"
}
