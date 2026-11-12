import Foundation

public struct CmuxGlaedaExecutionLocalization {
    public init() {}

    public func string(_ key: StaticString, defaultValue: String) -> String {
        String(
            localized: key,
            defaultValue: String.LocalizationValue(stringLiteral: defaultValue),
            bundle: .module
        )
    }

    public func format(
        _ key: StaticString,
        defaultValue: String,
        _ arguments: any CVarArg...
    ) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: Locale.current,
            arguments: arguments
        )
    }

    public func contractError(_ error: CmuxGlaedaExecutionContractError) -> String {
        switch error {
        case .invalidRequest:
            string(
                "glaeda.cli.error.invalidRequest",
                defaultValue: "The execution request is invalid."
            )
        case .invalidReceipt:
            string(
                "glaeda.cli.error.invalidReceipt",
                defaultValue: "The execution receipt does not match this request."
            )
        case .requestDigestMismatch:
            string(
                "glaeda.cli.error.requestDigestMismatch",
                defaultValue: "The execution receipt request digest does not match."
            )
        case .invalidWorkloadReceiptDigest:
            string(
                "glaeda.cli.error.invalidWorkloadDigest",
                defaultValue: "The workload receipt digest is invalid."
            )
        case .terminalEvidenceMissing:
            string(
                "glaeda.cli.error.terminalEvidenceMissing",
                defaultValue: "The terminal result is missing workload evidence."
            )
        case .invalidJSON:
            string(
                "glaeda.cli.error.invalidJSON",
                defaultValue: "The input document is invalid JSON."
            )
        case .objectRequired:
            string(
                "glaeda.cli.error.objectRequired",
                defaultValue: "The input document must be a JSON object."
            )
        case .noncanonicalJSON:
            string(
                "glaeda.cli.error.noncanonicalJSON",
                defaultValue: "The input document must use canonical JSON."
            )
        case .documentTooLarge:
            string(
                "glaeda.cli.error.documentTooLarge",
                defaultValue: "The input document exceeds the size limit."
            )
        case .encodingFailed:
            string(
                "glaeda.cli.error.encodingFailed",
                defaultValue: "The document could not be encoded."
            )
        }
    }
}
