import CommonCrypto
public import Foundation

/// Firefox's saved-password encryption (NSS, `key4.db`): the master key in
/// `nssPrivate.a11` and the check value in `metaData` ("password-check")
/// are sealed with PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC) or, in older
/// profiles, PKCS#12 SHA-1 + 3DES; both start from SHA-1(global salt +
/// primary password), with an empty primary password when none is set.
/// Each `logins.json` value is DER {key id, {cipher, IV}, ciphertext} under
/// that master key (3DES-CBC or AES-256-CBC). The master key and every
/// decrypted value are `SecretBytes`; the primary password is the caller's
/// `SecretBytes` and is never kept.
public struct FirefoxPasswordCrypto: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The profile has a primary password and none (or an empty one) was given.
        case primaryPasswordNeeded
        /// The primary password given does not open the profile.
        case wrongPrimaryPassword
        /// `key4.db` lacks the tables or rows NSS writes, or a blob is not NSS's DER.
        case malformed
        /// A cipher or key derivation this reader does not know.
        case unsupportedScheme
        /// The master key does not open this value.
        case undecryptable
    }

    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let hmacSHA256 = "1.2.840.113549.2.9"
    static let aes256CBC = "2.16.840.1.101.3.4.1.42"
    static let sha1TripleDES = "1.2.840.113549.1.12.5.1.3"
    static let tripleDESCBC = "1.2.840.113549.3.7"
    static let check = Array("password-check".utf8)

    /// Master keys by their CKA_ID (`nssPrivate.a102`), which each login blob names.
    private let keys: [[UInt8]: SecretBytes]

    /// Opens `key4.db` (a private copy) with `primaryPassword` (nil: none).
    init(key4: SQLiteSnapshot, primaryPassword: SecretBytes?) throws(Failure) {
        let primary = primaryPassword ?? SecretBytes(capacity: 0) { _ in 0 }
        var salt: [UInt8]?
        var checkBlob: [UInt8]?
        do {
            try key4.query("SELECT item1, item2 FROM metaData WHERE id = 'password'") { row in
                salt = row.data(0).map { Array($0) }
                checkBlob = row.data(1).map { Array($0) }
                return false
            }
        } catch {
            throw .malformed
        }
        guard let salt, let checkBlob else { throw .malformed }
        // No primary password (or an empty one) that fails means the profile has one; a given one that fails is wrong.
        let refusal: Failure = (primaryPassword?.isEmpty ?? true) ? .primaryPasswordNeeded : .wrongPrimaryPassword
        let opened: SecretBytes
        do throws(Failure) {
            opened = try Self.openPBE(checkBlob, globalSalt: salt, password: primary)
        } catch .undecryptable {
            throw refusal
        }
        let checks = opened.withUnsafeBytes { $0.starts(with: Self.check) }
        guard checks else { throw refusal }

        var sealed: [([UInt8], [UInt8])] = []
        do {
            try key4.query("SELECT a11, a102 FROM nssPrivate") { row in
                if let a11 = row.data(0), let a102 = row.data(1) { sealed.append((Array(a11), Array(a102))) }
                return true
            }
        } catch {
            throw .malformed
        }
        var keys: [[UInt8]: SecretBytes] = [:]
        for (a11, id) in sealed {
            guard let key = try? Self.openPBE(a11, globalSalt: salt, password: primary), !key.isEmpty else { continue }
            keys[id] = key
        }
        guard !keys.isEmpty else { throw .malformed }
        self.keys = keys
    }

    /// Decrypts one `encryptedUsername` / `encryptedPassword` (base64 DER) into `SecretBytes`.
    public func decrypt(_ base64: String) throws(Failure) -> SecretBytes {
        guard let blob = Data(base64Encoded: base64) else { throw .malformed }
        do {
            let root = try NSSDER(Array(blob))
            let keyID = try root.child(0, tag: NSSDER.octetString).content
            let algorithm = try root.child(1, tag: NSSDER.sequence)
            let cipher = try algorithm.child(0, tag: NSSDER.objectIdentifier).oid()
            let iv = try algorithm.child(1, tag: NSSDER.octetString).content
            let ciphertext = try root.child(2, tag: NSSDER.octetString).content
            guard let key = keys[keyID] ?? (keys.count == 1 ? keys.first?.value : nil) else { throw Failure.undecryptable }
            switch cipher {
            case Self.tripleDESCBC:
                guard key.count >= kCCKeySize3DES, iv.count == kCCBlockSize3DES else { throw Failure.undecryptable }
                return try Self.crypt(CCAlgorithm(kCCAlgorithm3DES), key: key, keyLength: kCCKeySize3DES, iv: iv, ciphertext)
            case Self.aes256CBC:
                guard key.count >= kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw Failure.undecryptable }
                return try Self.crypt(CCAlgorithm(kCCAlgorithmAES), key: key, keyLength: kCCKeySizeAES256, iv: iv, ciphertext)
            default:
                throw Failure.unsupportedScheme
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .malformed
        }
    }

    // MARK: Password-based encryption of key4.db items

    /// Opens a key4.db item: DER {{algorithm, parameters}, ciphertext}.
    static func openPBE(_ blob: [UInt8], globalSalt: [UInt8], password: SecretBytes) throws(Failure) -> SecretBytes {
        do {
            let root = try NSSDER(blob)
            let algorithm = try root.child(0, tag: NSSDER.sequence)
            let ciphertext = try root.child(1, tag: NSSDER.octetString).content
            let oid = try algorithm.child(0, tag: NSSDER.objectIdentifier).oid()
            let hashed = sha1([globalSalt], secret: password)
            switch oid {
            case pbes2:
                let parameters = try algorithm.child(1, tag: NSSDER.sequence)
                let derivation = try parameters.child(0, tag: NSSDER.sequence)
                guard try derivation.child(0, tag: NSSDER.objectIdentifier).oid() == pbkdf2 else { throw Failure.unsupportedScheme }
                let pbkdf = try derivation.child(1, tag: NSSDER.sequence)
                let fields = try pbkdf.children()
                let salt = try pbkdf.child(0, tag: NSSDER.octetString).content
                let iterations = try pbkdf.child(1, tag: NSSDER.integer).smallInteger()
                let keyLength = try pbkdf.child(2, tag: NSSDER.integer).smallInteger()
                if fields.count > 3 {
                    guard try fields[3].child(0, tag: NSSDER.objectIdentifier).oid() == hmacSHA256 else { throw Failure.unsupportedScheme }
                }
                let scheme = try parameters.child(1, tag: NSSDER.sequence)
                guard try scheme.child(0, tag: NSSDER.objectIdentifier).oid() == aes256CBC, keyLength == kCCKeySizeAES256,
                      (1...10_000_000).contains(iterations) else { throw Failure.unsupportedScheme }
                var iv = try scheme.child(1, tag: NSSDER.octetString).content
                // NSS stores a 14-byte IV; the cipher IV is it with its own DER header in front.
                if iv.count == 14 { iv = [NSSDER.octetString, 14] + iv }
                guard iv.count == kCCBlockSizeAES128 else { throw Failure.malformed }
                let key = SecretBytes(capacity: keyLength) { out in
                    let status = hashed.withUnsafeBytes { password in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                             salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                    }
                    return status == kCCSuccess ? keyLength : 0
                }
                guard key.count == keyLength else { throw Failure.undecryptable }
                return try crypt(CCAlgorithm(kCCAlgorithmAES), key: key, keyLength: keyLength, iv: iv, ciphertext)
            case sha1TripleDES:
                let parameters = try algorithm.child(1, tag: NSSDER.sequence)
                let entrySalt = try parameters.child(0, tag: NSSDER.octetString).content
                let (key, iv) = tripleDESKey(hashed: hashed, entrySalt: entrySalt)
                return try crypt(CCAlgorithm(kCCAlgorithm3DES), key: key, keyLength: kCCKeySize3DES, iv: iv, ciphertext)
            default:
                throw Failure.unsupportedScheme
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .malformed
        }
    }

    /// NSS's PKCS#12-style SHA-1 derivation for pbeWithSha1AndTripleDES-CBC.
    static func tripleDESKey(hashed: SecretBytes, entrySalt: [UInt8]) -> (key: SecretBytes, iv: [UInt8]) {
        let padded = entrySalt + [UInt8](repeating: 0, count: max(0, 20 - entrySalt.count))
        let chp = sha1([entrySalt], prefix: hashed)
        let k1 = hmacSHA1(key: chp, padded + entrySalt)
        let tk = hmacSHA1(key: chp, padded)
        let k2 = tk.withUnsafeBytes { hmacSHA1(key: chp, Array($0) + entrySalt) }
        let key = SecretBytes(capacity: 40) { out in
            k1.withUnsafeBytes { a in k2.withUnsafeBytes { b in
                for index in 0..<20 {
                    out[index] = a[index]
                    out[20 + index] = b[index]
                }
            } }
            return 40
        }
        let iv = key.withUnsafeBytes { Array($0[32..<40]) }
        return (key, iv)
    }

    // MARK: Primitives (outputs in SecretBytes)

    static func sha1(_ parts: [[UInt8]], secret: SecretBytes) -> SecretBytes {
        SecretBytes(capacity: Int(CC_SHA1_DIGEST_LENGTH)) { out in
            var context = CC_SHA1_CTX()
            CC_SHA1_Init(&context)
            for part in parts { CC_SHA1_Update(&context, part, CC_LONG(part.count)) }
            secret.withUnsafeBytes { _ = CC_SHA1_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
            CC_SHA1_Final(out.baseAddress?.assumingMemoryBound(to: UInt8.self), &context)
            _ = memset_s(&context, MemoryLayout<CC_SHA1_CTX>.size, 0, MemoryLayout<CC_SHA1_CTX>.size)
            return Int(CC_SHA1_DIGEST_LENGTH)
        }
    }

    static func sha1(_ parts: [[UInt8]], prefix: SecretBytes) -> SecretBytes {
        SecretBytes(capacity: Int(CC_SHA1_DIGEST_LENGTH)) { out in
            var context = CC_SHA1_CTX()
            CC_SHA1_Init(&context)
            prefix.withUnsafeBytes { _ = CC_SHA1_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
            for part in parts { CC_SHA1_Update(&context, part, CC_LONG(part.count)) }
            CC_SHA1_Final(out.baseAddress?.assumingMemoryBound(to: UInt8.self), &context)
            _ = memset_s(&context, MemoryLayout<CC_SHA1_CTX>.size, 0, MemoryLayout<CC_SHA1_CTX>.size)
            return Int(CC_SHA1_DIGEST_LENGTH)
        }
    }

    static func hmacSHA1(key: SecretBytes, _ message: [UInt8]) -> SecretBytes {
        SecretBytes(capacity: Int(CC_SHA1_DIGEST_LENGTH)) { out in
            key.withUnsafeBytes { keyBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, keyBytes.count, message, message.count, out.baseAddress)
            }
            return Int(CC_SHA1_DIGEST_LENGTH)
        }
    }

    /// CBC with PKCS#7 padding; `key` may be longer than `keyLength` (only its start is used).
    static func crypt(_ algorithm: CCAlgorithm, key: SecretBytes, keyLength: Int, iv: [UInt8], _ input: [UInt8],
                      operation: CCOperation = CCOperation(kCCDecrypt)) throws(Failure) -> SecretBytes {
        let block = algorithm == CCAlgorithm(kCCAlgorithm3DES) ? kCCBlockSize3DES : kCCBlockSizeAES128
        // Whole blocks only: CommonCrypto answers a cut-off block with bytes, not an error.
        if operation == CCOperation(kCCDecrypt) { guard !input.isEmpty, input.count % block == 0 else { throw .undecryptable } }
        var status = CCCryptorStatus(kCCSuccess)
        let output = SecretBytes(capacity: input.count + block) { out in
            var written = 0
            status = key.withUnsafeBytes { keyBytes in
                CCCrypt(operation, algorithm, CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, keyLength, iv,
                        input, input.count, out.baseAddress, out.count, &written)
            }
            return status == kCCSuccess ? written : 0
        }
        guard status == kCCSuccess else { throw .undecryptable }
        return output
    }
}
