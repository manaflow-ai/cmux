extension ResourceEmitter {
    /// The Swift name of the catalog's error type.
    static let errorTypeName = ResourceSwiftName.prefix + "ResourceError"

    /// One catalog error: its code, the `Details` case and the type of its `details`.
    struct ErrorCase: Equatable {
        let code: String
        let caseName: String
        let detailsType: String
    }

    /// The catalog's errors in code order, and the details structs of those whose `details` is
    /// inline (`V2<Code>Details`); a `details` that names a catalog type uses that type.
    func errorCases() throws(ResourceEmitterError) -> (cases: [ErrorCase], declarations: [ResourceDeclaration]) {
        var cases: [ErrorCase] = []
        var declarations: [ResourceDeclaration] = []
        for code in catalog.errors.keys.sorted() {
            guard let descriptor = catalog.errors[code] else { continue }
            let path = "$.errors.\(code)"
            let hint = try ResourceSwiftName.prefix + ResourceSwiftName.upperCamel(code, path: path) + "Details"
            let detailsType: String
            if case .object(let fields) = descriptor.details {
                declarations.append(.object(try renderer.object(
                    hint, fields: fields, path: path + ".details", doc: ["/// The `details` of `\(code)`."])))
                detailsType = hint
            } else {
                detailsType = try renderer.swiftType(descriptor.details, hint: hint, path: path + ".details",
                                                     nested: &declarations)
            }
            cases.append(ErrorCase(code: code, caseName: try ResourceSwiftName.member(code, path: path).spelling,
                                   detailsType: detailsType))
        }
        try ResourceTypeRenderer.checkUnique(cases.map(\.caseName) + ["unknown", "malformed"], path: "$.errors")
        return (cases, declarations)
    }

    /// `V2ResourceError` and the details types it needs.
    func errorDeclarations() throws(ResourceEmitterError) -> [ResourceDeclaration] {
        let (cases, declarations) = try errorCases()
        return declarations + [.source(name: Self.errorTypeName, lines: errorSource(cases))]
    }

    private func errorSource(_ cases: [ErrorCase]) -> [String] {
        let name = Self.errorTypeName
        var out = [
            "/// The `error` of an `ok: false` resource response (resource-api-v2.md): the catalog's code with",
            "/// that code's typed `details`. `unknown` keeps the raw details of a code this build does not know, and",
            "/// `malformed` those of a known code whose details do not have the catalog's shape (an older or newer",
            "/// daemon): `code`, `message` and `retryable` still decode, so the caller can still retry or show it.",
            "public struct \(name): Error, Codable, Sendable, Equatable {",
            "    /// Every code the catalog declares, sorted.",
            "    public static let codes: [String] = [",
        ]
        out += cases.map { "        \(ResourceSourceWriter.literal($0.code))," }
        out += [
            "    ]",
            "",
            "    public var code: String",
            "    public var message: String",
            "    public var retryable: Bool",
            "    public var details: Details",
            "",
            "    public enum Details: Sendable, Equatable {",
        ]
        out += cases.map { "        case \($0.caseName)(\($0.detailsType))" }
        out += [
            "        case unknown(ResourceJSON)",
            "        case malformed(ResourceJSON)",
            "    }",
            "",
            "    enum CodingKeys: String, CodingKey {",
            "        case code, message, retryable, details",
            "    }",
            "",
            "    public init(code: String, message: String, retryable: Bool, details: Details) {",
            "        self.code = code",
            "        self.message = message",
            "        self.retryable = retryable",
            "        self.details = details",
            "    }",
            "",
            "    public init(from decoder: any Decoder) throws {",
            "        let container = try decoder.container(keyedBy: CodingKeys.self)",
            "        let code = try container.decode(String.self, forKey: .code)",
            "        self.code = code",
            "        self.message = try container.decode(String.self, forKey: .message)",
            "        self.retryable = try container.decode(Bool.self, forKey: .retryable)",
            "        switch code {",
        ]
        for errorCase in cases {
            out.append("        case \(ResourceSourceWriter.literal(errorCase.code)):")
            out.append("            if let value = try? container.decode(\(errorCase.detailsType).self, forKey: .details) {")
            out.append("                self.details = .\(errorCase.caseName)(value)")
            out.append("            } else {")
            out.append("                self.details = .malformed(try container.decode(ResourceJSON.self, forKey: .details))")
            out.append("            }")
        }
        out += [
            "        default:",
            "            self.details = .unknown(try container.decode(ResourceJSON.self, forKey: .details))",
            "        }",
            "    }",
            "",
            "    public func encode(to encoder: any Encoder) throws {",
            "        var container = encoder.container(keyedBy: CodingKeys.self)",
            "        try container.encode(self.code, forKey: .code)",
            "        try container.encode(self.message, forKey: .message)",
            "        try container.encode(self.retryable, forKey: .retryable)",
            "        switch self.details {",
        ]
        out += cases.map { "        case .\($0.caseName)(let value): try container.encode(value, forKey: .details)" }
        out += [
            "        case .unknown(let raw), .malformed(let raw): try container.encode(raw, forKey: .details)",
            "        }",
            "    }",
            "}",
        ]
        return out
    }
}
