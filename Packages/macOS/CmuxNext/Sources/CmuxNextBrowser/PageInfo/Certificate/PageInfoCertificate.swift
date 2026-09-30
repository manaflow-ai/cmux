import CryptoKit
public import Foundation

/// A distinguished name's fields Chrome's certificate viewer shows.
public nonisolated struct CertificateName: Hashable, Sendable {
    public var commonName: String?
    public var organization: String?
    public var organizationalUnit: String?
    /// Every attribute in order, as (short name or OID, value).
    public var attributes: [CertificateAttribute]

    public init(attributes: [CertificateAttribute]) {
        self.attributes = attributes
        commonName = attributes.last { $0.oid == "2.5.4.3" }?.value
        organization = attributes.last { $0.oid == "2.5.4.10" }?.value
        organizationalUnit = attributes.last { $0.oid == "2.5.4.11" }?.value
    }

    /// RFC 4514-style one-line form, most significant first ("CN = x, O = y").
    public var summary: String {
        attributes.reversed().map { "\($0.shortName) = \($0.value)" }.joined(separator: "\n")
    }
}

public nonisolated struct CertificateAttribute: Hashable, Sendable {
    public var oid: String
    public var value: String

    static let shortNames = [
        "2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.10": "O", "2.5.4.11": "OU",
        "2.5.4.5": "serialNumber", "1.2.840.113549.1.9.1": "emailAddress", "2.5.4.97": "organizationIdentifier",
        "1.3.6.1.4.1.311.60.2.1.3": "jurisdictionC", "2.5.4.15": "businessCategory",
    ]

    public var shortName: String { Self.shortNames[oid] ?? oid }
}

/// One X.509 certificate, parsed from DER without private Security API.
public nonisolated struct PageInfoCertificate: Hashable, Sendable {
    public var der: Data
    public var version: Int
    /// Serial number bytes as colon-separated uppercase hex.
    public var serialNumber: String
    public var signatureAlgorithm: String
    public var issuer: CertificateName
    public var subject: CertificateName
    public var notBefore: Date?
    public var notAfter: Date?
    public var publicKeyAlgorithm: String
    public var subjectAlternativeNames: [String]
    /// DER of SubjectPublicKeyInfo.
    public var subjectPublicKeyInfo: Data

    public init(der: Data) throws {
        self.der = der
        var outer = DERReader(der)
        let certificate = try outer.next()
        let parts = try certificate.children()
        guard parts.count >= 3 else { throw DERError.unexpected("certificate") }
        var tbs = try parts[0].children()
        version = 1
        if let first = tbs.first, first.tag == 0xA0 {
            version = (try first.children().first?.integer ?? 0) + 1
            tbs.removeFirst()
        }
        guard tbs.count >= 6 else { throw DERError.unexpected("tbsCertificate") }
        serialNumber = tbs[0].content.map { String(format: "%02X", $0) }.joined(separator: ":")
        signatureAlgorithm = Self.algorithmName(try parts[1].children().first?.objectIdentifier)
        issuer = try Self.name(tbs[2])
        let validity = try tbs[3].children()
        notBefore = validity.first?.date
        notAfter = validity.count > 1 ? validity[1].date : nil
        subject = try Self.name(tbs[4])
        subjectPublicKeyInfo = tbs[5].encoded
        publicKeyAlgorithm = Self.algorithmName(try tbs[5].children().first?.children().first?.objectIdentifier)
        subjectAlternativeNames = try Self.alternativeNames(in: tbs.dropFirst(6).first { $0.tag == 0xA3 })
    }

    /// Lowercase hex SHA-256 of the whole certificate (Chrome's
    /// "SHA-256 Fingerprints: Certificate").
    public var sha256Fingerprint: String { Self.hex(SHA256.hash(data: der)) }
    /// Lowercase hex SHA-256 of SubjectPublicKeyInfo ("Public Key").
    public var publicKeySHA256: String { Self.hex(SHA256.hash(data: subjectPublicKeyInfo)) }
    public var sha1Fingerprint: String { Self.hex(Insecure.SHA1.hash(data: der)) }

    /// Valid at `date` by its validity period only (not chain trust).
    public func isWithinValidity(at date: Date = Date()) -> Bool {
        guard let notBefore, let notAfter else { return false }
        return notBefore <= date && date <= notAfter
    }

    /// PEM text of the certificate.
    public var pem: String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func name(_ element: DERElement) throws -> CertificateName {
        var attributes: [CertificateAttribute] = []
        for rdn in try element.children() {
            for pair in try rdn.children() {
                let fields = try pair.children()
                guard fields.count == 2, let oid = fields[0].objectIdentifier else { continue }
                attributes.append(CertificateAttribute(oid: oid, value: fields[1].string ?? fields[1].content.base64EncodedString()))
            }
        }
        return CertificateName(attributes: attributes)
    }

    private static func alternativeNames(in extensions: DERElement?) throws -> [String] {
        guard let list = try extensions?.children().first?.children() else { return [] }
        for item in list {
            let fields = try item.children()
            guard fields.first?.objectIdentifier == "2.5.29.17", let value = fields.last, value.tag == 0x04 else { continue }
            var reader = DERReader(value.content)
            let names = try reader.next().children()
            return names.compactMap { name in
                switch name.tag {
                case 0x82: name.string
                case 0x87: name.content.count == 4 ? name.content.map(String.init).joined(separator: ".") : nil
                default: nil
                }
            }
        }
        return []
    }

    static func algorithmName(_ oid: String?) -> String {
        switch oid {
        case "1.2.840.113549.1.1.1": "PKCS #1 RSA Encryption"
        case "1.2.840.113549.1.1.5": "PKCS #1 SHA-1 With RSA Encryption"
        case "1.2.840.113549.1.1.11": "PKCS #1 SHA-256 With RSA Encryption"
        case "1.2.840.113549.1.1.12": "PKCS #1 SHA-384 With RSA Encryption"
        case "1.2.840.113549.1.1.13": "PKCS #1 SHA-512 With RSA Encryption"
        case "1.2.840.113549.1.1.10": "RSA-PSS"
        case "1.2.840.10045.2.1": "Elliptic Curve Public Key"
        case "1.2.840.10045.4.3.2": "X9.62 ECDSA Signature with SHA-256"
        case "1.2.840.10045.4.3.3": "X9.62 ECDSA Signature with SHA-384"
        case "1.2.840.10045.4.3.4": "X9.62 ECDSA Signature with SHA-512"
        case "1.3.101.112": "Ed25519"
        case let other?: other
        case nil: "?"
        }
    }
}
