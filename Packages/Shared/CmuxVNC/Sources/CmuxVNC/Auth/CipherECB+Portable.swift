#if !canImport(CommonCrypto)
import _CryptoExtras
import Crypto

extension CipherECB {
    /// Each block through the raw cipher: swift-crypto's AES block function
    /// (`AES.permute`, BoringSSL's AES_encrypt) and `DESBlockCipher`, which
    /// swift-crypto does not offer. Same contract as CommonCrypto's ECB mode
    /// with no padding.
    func encrypt(_ plaintext: [UInt8]) -> [UInt8]? {
        switch algorithm {
        case .des:
            guard let cipher = DESBlockCipher(key: key) else { return nil }
            return blocks(of: plaintext, size: DESBlockCipher.blockSize) { cipher.encrypt($0) }
        case .aes128:
            guard [16, 24, 32].contains(key.count) else { return nil }
            let symmetricKey = SymmetricKey(data: key)
            return blocks(of: plaintext, size: 16) { block in
                var block = block
                guard (try? AES.permute(&block, key: symmetricKey)) != nil else { return nil }
                return block
            }
        }
    }

    private func blocks(of plaintext: [UInt8], size: Int, _ encryptBlock: ([UInt8]) -> [UInt8]?) -> [UInt8]? {
        guard plaintext.count.isMultiple(of: size) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(plaintext.count)
        for start in Swift.stride(from: 0, to: plaintext.count, by: size) {
            guard let block = encryptBlock(Array(plaintext[start ..< start + size])) else { return nil }
            output += block
        }
        return output
    }
}
#endif
