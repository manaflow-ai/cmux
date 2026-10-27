#if canImport(CommonCrypto)
import CommonCrypto

extension CipherECB {
    func encrypt(_ plaintext: [UInt8]) -> [UInt8]? {
        let ccAlgorithm = switch algorithm {
        case .des: CCAlgorithm(kCCAlgorithmDES)
        case .aes128: CCAlgorithm(kCCAlgorithmAES128)
        }
        var output = [UInt8](repeating: 0, count: plaintext.count)
        let capacity = output.count
        var moved = 0
        // SAFETY: CCCrypt reads key.count bytes of `key` and plaintext.count bytes of `plaintext`
        // (the counts passed), takes no IV in ECB mode, writes at most `capacity` = output.count
        // bytes into `output` and one Int into `moved`; Swift keeps every array and `moved` alive
        // and in place for this call only, and CCCrypt keeps no pointer after it returns.
        let status = unsafe CCCrypt(CCOperation(kCCEncrypt), ccAlgorithm, CCOptions(kCCOptionECBMode),
                                    key, key.count, nil, plaintext, plaintext.count, &output, capacity, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}
#endif
