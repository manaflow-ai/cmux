/// A link cert signature made once by CryptoKit with the P-256 key whose raw
/// scalar is bytes 1...32; the backend test verifies the same values with
/// WebCrypto (trust-domain.test.ts), so both sides agree on the message.
struct CrossLanguageVector {
    static let x = "UVw9brnjlrkE0_7Kf1T9zQzB6Ze_N13KUVrQpsO0A18"
    static let y = "RTa-OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q"
    static let signature = "lFAR1qbkx_BmFC_YBYnFEoBF1NOjjVxLXgS-LmCCYRc23kiN_85-KmeADmU8mR3-Iexsnzb32CTuhM_cxcedDw"
}
