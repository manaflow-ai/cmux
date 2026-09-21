import CoreFoundation
import CryptoKit
import Foundation

extension CMUXCLI {
    static let glaedaUsage = """
    Usage: cmux glaeda <request|observe> [options]

    Exchange one caller-neutral semantic execution request with Glaeda.

    Subcommands:
      request
        --request-ref <ref>        CMUX caller correlation reference
        --work-ref <ref>           CMUX work correlation reference
        --repository <owner/repo>  Canonical Git repository identity
        --commit <40-hex>          Exact Git commit
        --tree <40-hex>            Exact Git tree
        [--reuse <prefer_valid_reuse|no_preference>]

        Emits canonical glaeda-external-execution-request/v1 JSON to stdout.
        No cmux socket, workspace target, machine, shell command, or environment
        is sent through this boundary.

      observe
        --request <path>           Exact request document previously emitted
        --receipt <path|->         Bounded Glaeda receipt, or - for stdin

        Validates request/result correlation and emits a bounded CMUX observation.
        Terminal states require a Glaeda workload-receipt digest.

    Examples:
      cmux glaeda request --request-ref cmux:exec:42 --work-ref cmux:work:42 \
        --repository owner/repo --commit <commit> --tree <tree>
      cmux glaeda observe --request request.json --receipt result.json
    """

    private static let glaedaRequestDocumentType = "glaeda-external-execution-request"
    private static let glaedaReceiptDocumentType = "glaeda-external-execution-receipt"
    private static let glaedaObservationDocumentType = "cmux-glaeda-execution-observation"
    private static let glaedaSchemaVersion = 1
    private static let glaedaMaxDocumentBytes = 4 * 1024
    private static let glaedaOperation = "verify_focused"
    private static let glaedaCapabilityClass = "credentialless_project"
    private static let glaedaReuseHints: Set<String> = ["prefer_valid_reuse", "no_preference"]
    private static let glaedaReceiptStates: Set<String> = [
        "planned",
        "refused",
        "ambiguous",
        "succeeded",
        "failed",
        "timed_out",
        "cleanup_incomplete",
    ]
    private static let glaedaTerminalStates: Set<String> = [
        "succeeded",
        "failed",
        "timed_out",
        "cleanup_incomplete",
    ]
    private static let glaedaZeroAuthority: [String: Bool] = [
        "authorizes_execution": false,
        "authorizes_redispatch": false,
        "authorizes_host_selection": false,
        "authorizes_cleanup": false,
    ]

    func runGlaedaCommand(commandArgs: [String]) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: Self.glaedaUsage)
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "request":
            let document = try glaedaRequestDocument(arguments: rest)
            cliWriteStdout(try Self.glaedaCanonicalJSON(document))
            cliWriteStdout(Data("\n".utf8))
        case "observe":
            let observation = try glaedaObservation(arguments: rest)
            cliWriteStdout(try Self.glaedaCanonicalJSON(observation))
            cliWriteStdout(Data("\n".utf8))
        case "help", "--help", "-h":
            guard rest.isEmpty else {
                throw CLIError(message: "glaeda: help accepts no additional arguments")
            }
            cliWriteStdout(Self.glaedaUsage + "\n")
        default:
            throw CLIError(
                message: "Unknown glaeda subcommand '\(subcommand)'.\n\n\(Self.glaedaUsage)"
            )
        }
    }

    private func glaedaRequestDocument(arguments: [String]) throws -> [String: Any] {
        let options = try Self.glaedaParseOptions(
            arguments,
            command: "glaeda request",
            allowed: [
                "--request-ref",
                "--work-ref",
                "--repository",
                "--commit",
                "--tree",
                "--reuse",
            ]
        )
        let requestRef = try Self.glaedaRequiredOption("--request-ref", options: options)
        let workRef = try Self.glaedaRequiredOption("--work-ref", options: options)
        let repository = try Self.glaedaRequiredOption("--repository", options: options)
        let commit = try Self.glaedaRequiredOption("--commit", options: options)
        let tree = try Self.glaedaRequiredOption("--tree", options: options)
        let reuse = options["--reuse"] ?? "prefer_valid_reuse"

        guard Self.glaedaValidToken(requestRef) else {
            throw CLIError(message: "glaeda request: --request-ref is invalid")
        }
        guard Self.glaedaValidToken(workRef) else {
            throw CLIError(message: "glaeda request: --work-ref is invalid")
        }
        guard Self.glaedaValidRepository(repository) else {
            throw CLIError(message: "glaeda request: --repository must be owner/repo")
        }
        guard Self.glaedaValidOID(commit), Self.glaedaValidOID(tree) else {
            throw CLIError(message: "glaeda request: --commit and --tree must be exact 40-hex Git object ids")
        }
        guard Self.glaedaReuseHints.contains(reuse) else {
            throw CLIError(message: "glaeda request: --reuse must be prefer_valid_reuse or no_preference")
        }

        let request: [String: Any] = [
            "document_type": Self.glaedaRequestDocumentType,
            "schema_version": Self.glaedaSchemaVersion,
            "external_request_ref": requestRef,
            "source": [
                "repository": repository,
                "commit": commit,
                "tree": tree,
            ],
            "operation": Self.glaedaOperation,
            "requested_capability_class": Self.glaedaCapabilityClass,
            "reuse_hint": reuse,
            "correlation": [
                "work_ref": workRef,
            ],
        ]
        let encoded = try Self.glaedaCanonicalJSON(request)
        guard encoded.count <= Self.glaedaMaxDocumentBytes else {
            throw CLIError(message: "glaeda request: document exceeds its fixed ceiling")
        }
        return request
    }

    private func glaedaObservation(arguments: [String]) throws -> [String: Any] {
        let options = try Self.glaedaParseOptions(
            arguments,
            command: "glaeda observe",
            allowed: ["--request", "--receipt"]
        )
        let requestPath = try Self.glaedaRequiredOption("--request", options: options)
        let receiptPath = try Self.glaedaRequiredOption("--receipt", options: options)

        let requestData = try Self.glaedaReadDocument(path: requestPath, label: "request")
        let receiptData = try Self.glaedaReadDocument(path: receiptPath, label: "receipt")
        let request = try Self.glaedaDecodeObject(requestData, label: "request")
        let receipt = try Self.glaedaDecodeObject(receiptData, label: "receipt")
        let validatedRequest = try Self.glaedaValidateRequest(request)
        let validatedReceipt = try Self.glaedaValidateReceipt(
            receipt,
            request: validatedRequest,
            canonicalRequestData: try Self.glaedaCanonicalJSON(request)
        )

        return [
            "document_type": Self.glaedaObservationDocumentType,
            "schema_version": 1,
            "external_request_ref": validatedRequest.requestRef,
            "work_ref": validatedRequest.workRef,
            "state": validatedReceipt.state,
            "request_sha256": validatedReceipt.requestDigest,
            "workload_receipt_sha256": validatedReceipt.workloadDigest ?? NSNull(),
        ]
    }

    private struct GlaedaValidatedRequest {
        let requestRef: String
        let workRef: String
        let repository: String
        let commit: String
        let tree: String
    }

    private struct GlaedaValidatedReceipt {
        let state: String
        let requestDigest: String
        let workloadDigest: String?
    }

    private static func glaedaValidateRequest(_ value: [String: Any]) throws -> GlaedaValidatedRequest {
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
              value["document_type"] as? String == glaedaRequestDocumentType,
              glaedaInteger(value["schema_version"]) == glaedaSchemaVersion,
              value["operation"] as? String == glaedaOperation,
              value["requested_capability_class"] as? String == glaedaCapabilityClass,
              let requestRef = value["external_request_ref"] as? String,
              glaedaValidToken(requestRef),
              let reuseHint = value["reuse_hint"] as? String,
              glaedaReuseHints.contains(reuseHint),
              let source = value["source"] as? [String: Any],
              Set(source.keys) == Set(["repository", "commit", "tree"]),
              let repository = source["repository"] as? String,
              glaedaValidRepository(repository),
              let commit = source["commit"] as? String,
              glaedaValidOID(commit),
              let tree = source["tree"] as? String,
              glaedaValidOID(tree),
              let correlation = value["correlation"] as? [String: Any],
              Set(correlation.keys) == Set(["work_ref"]),
              let workRef = correlation["work_ref"] as? String,
              glaedaValidToken(workRef)
        else {
            throw CLIError(message: "glaeda observe: request document does not match the CMUX/Glaeda v1 contract")
        }
        return GlaedaValidatedRequest(
            requestRef: requestRef,
            workRef: workRef,
            repository: repository,
            commit: commit,
            tree: tree
        )
    }

    private static func glaedaValidateReceipt(
        _ value: [String: Any],
        request: GlaedaValidatedRequest,
        canonicalRequestData: Data
    ) throws -> GlaedaValidatedReceipt {
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
              value["document_type"] as? String == glaedaReceiptDocumentType,
              glaedaInteger(value["schema_version"]) == glaedaSchemaVersion,
              value["external_request_ref"] as? String == request.requestRef,
              value["operation"] as? String == glaedaOperation,
              let source = value["source"] as? [String: Any],
              Set(source.keys) == Set(["repository", "commit", "tree"]),
              source["repository"] as? String == request.repository,
              source["commit"] as? String == request.commit,
              source["tree"] as? String == request.tree,
              let correlation = value["correlation"] as? [String: Any],
              Set(correlation.keys) == Set(["work_ref"]),
              correlation["work_ref"] as? String == request.workRef,
              let authority = value["authority"] as? [String: Any],
              glaedaAuthorityIsZero(authority),
              let state = value["state"] as? String,
              glaedaReceiptStates.contains(state),
              let requestDigest = value["request_sha256"] as? String,
              glaedaValidSHA256(requestDigest)
        else {
            throw CLIError(message: "glaeda observe: receipt does not correlate to the request")
        }

        let expectedRequestDigest = glaedaSHA256(canonicalRequestData)
        guard requestDigest == expectedRequestDigest else {
            throw CLIError(message: "glaeda observe: receipt request digest does not match the request")
        }

        let workloadDigest: String?
        if value["workload_receipt_sha256"] is NSNull {
            workloadDigest = nil
        } else if let digest = value["workload_receipt_sha256"] as? String,
                  glaedaValidSHA256(digest) {
            workloadDigest = digest
        } else {
            throw CLIError(message: "glaeda observe: workload receipt digest is invalid")
        }

        if glaedaTerminalStates.contains(state), workloadDigest == nil {
            throw CLIError(message: "glaeda observe: terminal receipt is missing workload evidence")
        }

        if let refusal = value["refusal_code"], !(refusal is NSNull), !(refusal is String) {
            throw CLIError(message: "glaeda observe: refusal code is invalid")
        }
        if let resolved = value["resolved_workload"], !(resolved is NSNull), !(resolved is [String: Any]) {
            throw CLIError(message: "glaeda observe: resolved workload summary is invalid")
        }

        return GlaedaValidatedReceipt(
            state: state,
            requestDigest: requestDigest,
            workloadDigest: workloadDigest
        )
    }

    private static func glaedaAuthorityIsZero(_ value: [String: Any]) -> Bool {
        guard Set(value.keys) == Set(glaedaZeroAuthority.keys) else { return false }
        return glaedaZeroAuthority.allSatisfy { key, expected in
            glaedaBoolean(value[key]) == expected
        }
    }

    private static func glaedaBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func glaedaParseOptions(
        _ arguments: [String],
        command: String,
        allowed: Set<String>
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw CLIError(message: "\(command): unknown option '\(option)'")
            }
            guard result[option] == nil else {
                throw CLIError(message: "\(command): \(option) may only be supplied once")
            }
            index += 1
            guard index < arguments.count else {
                throw CLIError(message: "\(command): \(option) requires a value")
            }
            let value = arguments[index]
            guard !value.hasPrefix("--") else {
                throw CLIError(message: "\(command): \(option) requires a value")
            }
            result[option] = value
            index += 1
        }
        return result
    }

    private static func glaedaRequiredOption(
        _ key: String,
        options: [String: String]
    ) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw CLIError(message: "glaeda: missing required option \(key)")
        }
        return value
    }

    private static func glaedaReadDocument(path: String, label: String) throws -> Data {
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readData(ofLength: glaedaMaxDocumentBytes + 1)
        } else {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: path)
            } catch {
                throw CLIError(message: "glaeda observe: \(label) document is unavailable")
            }
            if let size = attributes[.size] as? NSNumber,
               size.uint64Value > UInt64(glaedaMaxDocumentBytes) {
                throw CLIError(message: "glaeda observe: \(label) document exceeds its fixed ceiling")
            }
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                throw CLIError(message: "glaeda observe: \(label) document is unavailable")
            }
        }
        guard data.count <= glaedaMaxDocumentBytes else {
            throw CLIError(message: "glaeda observe: \(label) document exceeds its fixed ceiling")
        }
        return data
    }

    private static func glaedaDecodeObject(_ data: Data, label: String) throws -> [String: Any] {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CLIError(message: "glaeda observe: \(label) document is invalid JSON")
        }
        guard let object = decoded as? [String: Any] else {
            throw CLIError(message: "glaeda observe: \(label) document must be a JSON object")
        }
        let canonical = try glaedaCanonicalJSON(object)
        let normalizedInput = data.last == 0x0A ? data.dropLast() : data[...]
        guard Data(normalizedInput) == canonical else {
            throw CLIError(message: "glaeda observe: \(label) document is not canonical JSON")
        }
        return object
    }

    private static func glaedaCanonicalJSON(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CLIError(message: "glaeda: JSON document is invalid")
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CLIError(message: "glaeda: JSON encoding failed")
        }
    }

    private static func glaedaSHA256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func glaedaInteger(_ value: Any?) -> Int? {
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

    private static func glaedaValidToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let bytes = Array(value.utf8)
        func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard let first = bytes.first, isAlphaNumeric(first) else { return false }
        let punctuation: Set<UInt8> = [46, 95, 58, 47, 64, 43, 45] // . _ : / @ + -
        return bytes.allSatisfy { isAlphaNumeric($0) || punctuation.contains($0) }
    }

    private static func glaedaValidRepository(_ value: String) -> Bool {
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

    private static func glaedaValidOID(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func glaedaValidSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
