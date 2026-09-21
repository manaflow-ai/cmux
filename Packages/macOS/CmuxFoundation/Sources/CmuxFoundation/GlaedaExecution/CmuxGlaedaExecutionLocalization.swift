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
                defaultValue: "The Glaeda request is invalid."
            )
        case .invalidReceipt:
            string(
                "glaeda.cli.error.invalidReceipt",
                defaultValue: "The Glaeda receipt does not match this request."
            )
        case .requestDigestMismatch:
            string(
                "glaeda.cli.error.requestDigestMismatch",
                defaultValue: "The Glaeda receipt request digest does not match."
            )
        case .invalidWorkloadReceiptDigest:
            string(
                "glaeda.cli.error.invalidWorkloadDigest",
                defaultValue: "The Glaeda workload receipt digest is invalid."
            )
        case .terminalEvidenceMissing:
            string(
                "glaeda.cli.error.terminalEvidenceMissing",
                defaultValue: "The Glaeda terminal result is missing workload evidence."
            )
        case .invalidJSON(let label):
            format(
                "glaeda.cli.error.invalidJSON",
                defaultValue: "The %@ document is invalid JSON.",
                label
            )
        case .objectRequired(let label):
            format(
                "glaeda.cli.error.objectRequired",
                defaultValue: "The %@ document must be a JSON object.",
                label
            )
        case .noncanonicalJSON(let label):
            format(
                "glaeda.cli.error.noncanonicalJSON",
                defaultValue: "The %@ document must use canonical JSON.",
                label
            )
        case .documentTooLarge(let label):
            format(
                "glaeda.cli.error.documentTooLarge",
                defaultValue: "The %@ document exceeds the size limit.",
                label
            )
        case .encodingFailed:
            string(
                "glaeda.cli.error.encodingFailed",
                defaultValue: "The Glaeda document could not be encoded."
            )
        }
    }
}
