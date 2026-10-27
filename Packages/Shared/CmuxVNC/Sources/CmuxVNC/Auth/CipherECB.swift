/// One-shot ECB encryption with no padding, the block cipher RFB's legacy
/// authentications use. `encrypt` returns nil for a key of the wrong size or a
/// plaintext that is not whole blocks. The cipher is the platform's: CommonCrypto
/// on Apple platforms (CipherECB+CommonCrypto.swift), swift-crypto and
/// `DESBlockCipher` elsewhere (CipherECB+Portable.swift).
struct CipherECB {
    enum Algorithm {
        /// Single DES: an 8-byte key (parity bits ignored), 8-byte blocks.
        case des
        /// AES: a 16-, 24- or 32-byte key, 16-byte blocks.
        case aes128
    }

    var algorithm: Algorithm
    var key: [UInt8]
}
