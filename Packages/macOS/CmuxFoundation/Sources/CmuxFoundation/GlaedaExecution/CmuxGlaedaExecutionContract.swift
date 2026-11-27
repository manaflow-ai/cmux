import CoreFoundation
import CryptoKit
public import Foundation

public struct CmuxGlaedaExecutionRequest: Equatable, Sendable {
    public let externalRequestRef: String
    public let workRef: String
    public let repository: String
    public let commit: String
    public let tree: String
    public let reuseHint: String

    public init(
        externalRequestRef: String,
        workRef: String,
        repository: String,
        commit: String,
        tree: String,
        reuseHint: String = "prefer_valid_reuse"
    ) {
        self.externalRequestRef = externalRequestRef
        self.workRef = workRef
        self.repository = repository
        self.commit = commit
        self.tree = tree
        self.reuseHint = reuseHint
    }
}

public struct CmuxGlaedaExecutionObservation: Equatable, Sendable {
    public let externalRequestRef: String
    public let workRef: String
    public let state: String
    public let requestSHA256: String
    public let workloadReceiptSHA256: String?

    public init(
        externalRequestRef: String,
        workRef: String,
        state: String,
        requestSHA256: String,
        workloadReceiptSHA256: String?
    ) {
        self.externalRequestRef = externalRequestRef
        self.workRef = workRef
        self.state = state
        self.requestSHA256 = requestSHA256
        self.workloadReceiptSHA256 = workloadReceiptSHA256
    }
}

public enum CmuxGlaedaExecutionContractError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidReceipt
    case requestDigestMismatch
    case invalidWorkloadReceiptDigest
    case terminalEvidenceMissing
    case invalidJSON(String)
    case objectRequired(String)
    case noncanonicalJSON(String)
    case documentTooLarge(String)
    case encodingFailed
}

public struct CmuxGlaedaExecutionContract: Sendable {
    public static let maxDocumentBytes = 4 * 1024

    private let requestDocumentType = "glaeda-external-execution-request"
    private let receiptDocumentType = "glaeda-external-execution-receipt"
    private let observationDocumentType = "cmux-glaeda-execution-observation"
    private let schemaVersion = 1
    private let operation = "verify_focused"
    private let capabilityClass = "credentialless_project"
    private let reuseHints: Set<String> = ["prefer_valid_reuse", "no_preference"]
    private let receiptStates: Set<String> = [
        "planned",
        "refused",
        "ambiguous",
        "succeeded",
        "failed",
        "timed_out",
        "cleanup_incomplete",
    ]
    private let terminalStates: Set<String> = [
        "succeeded",
        "failed",
        "timed_out",
        "cleanup_incomplete",
    ]
    private let zeroAuthority: [String: Bool] = [
        "authorizes_execution": false,
        "authorizes_redispatch": false,
        "authorizes_host_selection": false,
        "authorizes_cleanup": false,
    ]

    public init() {}

    public func encodeRequest(_ request: CmuxGlaedaExecutionRequest) throws -> Data {
        guard validToken(request.externalRequestRef),
              validToken(request.workRef),
              validRepository(request.repository),
              validOID(request.commit),
              validOID(request.tree),
              reuseHints.contains(request.reuseHint) else {
            throw CmuxGlaedaExecutionContractError.invalidRequest
        }

        let object: [String: Any] = [
            "document_type": requestDocumentType,
            "schema_version": schemaVersion,
            "external_request_ref": request.externalRequestRef,
            "source": [
                "repository": request.repository,
                "commit": request.commit,
                "tree": request.tree,
            ],
            "operation": operation,
            "requested_capability_class": capabilityClass,
            "reuse_hint": request.reuseHint,
            "correlation": [
                "work_ref": request.workRef,
            ],
        ]
        let encoded = try canonicalJSON(object)
        guard encoded.count <= Self.maxDocumentBytes else {
            throw CmuxGlaedaExecutionContractError.documentTooLarge("request")
        }
        return encoded + Data("\n".utf8)
    }

    public func decodeRequest(_ data: Data) throws -> CmuxGlaedaExecutionRequest {
        let object = try decodeCanonicalObject(data, label: "request")
        return try validateRequest(object)
    }

    public func observe(
        requestData: Data,
        receiptData: Data
    ) throws -> CmuxGlaedaExecutionObservation {
        let requestObject = try decodeCanonicalObject(requestData, label: "request")
        let request = try validateRequest(requestObject)
        let receiptObject = try decodeCanonicalObject(receiptData, label: "receipt")
        return try validateReceipt(
            receiptObject,
            request: request,
            canonicalRequestData: try canonicalJSON(requestObject)
        )
    }

    public func encodeObservation(_ observation: CmuxGlaedaExecutionObservation) throws -> Data {
        let object: [String: Any] = [
            "document_type": observationDocumentType,
            "schema_version": 1,
            "external_request_ref": observation.externalRequestRef,
            "work_ref": observation.workRef,
            "state": observation.state,
            "request_sha256": observation.requestSHA256,
            "workload_receipt_sha256": observation.workloadReceiptSHA256 ?? NSNull(),
        ]
        return try canonicalJSON(object) + Data("\n".utf8)
    }

    private func validateRequest(_ value: [String: Any]) throws -> CmuxGlaedaExecutionRequest {
        let expectedKeys: Set<String> = [
            "document_type",
            "schema_version",
            "external_request_ref",
            "source",
            "operation",
            "requested_capability_class",
            "reuse_hint",
            "correlation",
        ]
        guard Set(value.keys) == expectedKeys,
              value["document_type"] as? String == requestDocumentType,
              integer(value["schema_version"]) == schemaVersion,
              value["operation"] as? String == operation,
              value["requested_capability_class"] as? String == capabilityClass,
              let requestRef = value["external_request_ref"] as? String,
              validToken(requestRef),
              let reuseHint = value["reuse_hint"] as? String,
              reuseHints.contains(reuseHint),
              let source = value["source"] as? [String: Any],
              Set(source.keys) == Set(["repository", "commit", "tree"]),
              let repository = source["repository"] as? String,
              validRepository(repository),
              let commit = source["commit"] as? String,
              validOID(commit),
              let tree = source["tree"] as? String,
              validOID(tree),
              let correlation = value["correlation"] as? [String: Any],
              Set(correlation.keys) == Set(["work_ref"]),
              let workRef = correlation["work_ref"] as? String,
              validToken(workRef) else {
            throw CmuxGlaedaExecutionContractError.invalidRequest
        }
        return CmuxGlaedaExecutionRequest(
            externalRequestRef: requestRef,
            workRef: workRef,
            repository: repository,
            commit: commit,
            tree: tree,
            reuseHint: reuseHint
        )
    }

    private func validateReceipt(
        _ value: [String: Any],
        request: CmuxGlaedaExecutionRequest,
        canonicalRequestData: Data
    ) throws -> CmuxGlaedaExecutionObservation {
        let expectedKeys: Set<String> = [
            "document_type",
            "schema_version",
            "external_request_ref",
            "request_sha256",
            "correlation",
            "operation",
            "source",
            "state",
            "resolved_workload",
            "workload_receipt_sha256",
            "refusal_code",
            "authority",
        ]
        guard Set(value.keys) == expectedKeys,
              value["document_type"] as? String == receiptDocumentType,
              integer(value["schema_version"]) == schemaVersion,
              value["external_request_ref"] as? String == request.externalRequestRef,
              value["operation"] as? String == operation,
              let source = value["source"] as? [String: Any],
              Set(source.keys) == Set(["repository", "commit", "tree"]),
              source["repository"] as? String == request.repository,
              source["commit"] as? String == request.commit,
              source["tree"] as? String == request.tree,
              let correlation = value["correlation"] as? [String: Any],
              Set(correlation.keys) == Set(["work_ref"]),
              correlation["work_ref"] as? String == request.workRef,
              let authority = value["authority"] as? [String: Any],
              authorityIsZero(authority),
              let state = value["state"] as? String,
              receiptStates.contains(state),
              let requestDigest = value["request_sha256"] as? String,
              validSHA256(requestDigest) else {
            throw CmuxGlaedaExecutionContractError.invalidReceipt
        }

        guard requestDigest == sha256(canonicalRequestData) else {
            throw CmuxGlaedaExecutionContractError.requestDigestMismatch
        }

        let workloadDigest: String?
        if value["workload_receipt_sha256"] is NSNull {
            workloadDigest = nil
        } else if let digest = value["workload_receipt_sha256"] as? String,
                  validSHA256(digest) {
            workloadDigest = digest
        } else {
            throw CmuxGlaedaExecutionContractError.invalidWorkloadReceiptDigest
        }

        if terminalStates.contains(state), workloadDigest == nil {
            throw CmuxGlaedaExecutionContractError.terminalEvidenceMissing
        }

        if let refusal = value["refusal_code"],
           !(refusal is NSNull),
           !(refusal is String) {
            throw CmuxGlaedaExecutionContractError.invalidReceipt
        }
        if let resolved = value["resolved_workload"],
           !(resolved is NSNull),
           !(resolved is [String: Any]) {
            throw CmuxGlaedaExecutionContractError.invalidReceipt
        }

        return CmuxGlaedaExecutionObservation(
            externalRequestRef: request.externalRequestRef,
            workRef: request.workRef,
            state: state,
            requestSHA256: requestDigest,
            workloadReceiptSHA256: workloadDigest
        )
    }

    private func decodeCanonicalObject(_ data: Data, label: String) throws -> [String: Any] {
        guard data.count <= Self.maxDocumentBytes else {
            throw CmuxGlaedaExecutionContractError.documentTooLarge(label)
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CmuxGlaedaExecutionContractError.invalidJSON(label)
        }
        guard let object = decoded as? [String: Any] else {
            throw CmuxGlaedaExecutionContractError.objectRequired(label)
        }
        let canonical = try canonicalJSON(object)
        let normalizedInput = data.last == 0x0A ? data.dropLast() : data[...]
        guard Data(normalizedInput) == canonical else {
            throw CmuxGlaedaExecutionContractError.noncanonicalJSON(label)
        }
        return object
    }

    private func canonicalJSON(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CmuxGlaedaExecutionContractError.encodingFailed
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CmuxGlaedaExecutionContractError.encodingFailed
        }
    }

    private func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func authorityIsZero(_ value: [String: Any]) -> Bool {
        guard Set(value.keys) == Set(zeroAuthority.keys) else { return false }
        return zeroAuthority.allSatisfy { key, expected in
            boolean(value[key]) == expected
        }
    }

    private func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let numberType = String(cString: number.objCType)
        guard numberType != "f", numberType != "d" else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }

    private func validToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let bytes = Array(value.utf8)
        func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = bytes.first, isAlphaNumeric(first) else { return false }
        let punctuation: Set<UInt8> = [46, 95, 58, 47, 64, 43, 45]
        return bytes.allSatisfy { isAlphaNumeric($0) || punctuation.contains($0) }
    }

    private func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || [46, 95, 45].contains(byte)
            }
        }
    }

    private func validOID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func validSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
