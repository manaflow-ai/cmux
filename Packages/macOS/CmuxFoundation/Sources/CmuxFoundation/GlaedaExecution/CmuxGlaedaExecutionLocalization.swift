import Foundation

public struct CmuxGlaedaExecutionLocalization {
    public init() {}

    private static let resourceBundle: Bundle = {
        let bundleName = "CmuxFoundation_CmuxFoundation.bundle"
        var roots: [URL] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle.main.bundleURL,
        ].compactMap { $0 }

        // The cmux CLI is shipped inside Contents/Resources/bin. In that
        // layout Bundle.main points at the executable directory, while the
        // SwiftPM resource bundle lives in the containing app's Resources
        // directory. Walk a few parents so CLI help cannot trap when the
        // generated Bundle.module accessor cannot see the app bundle.
        var parent = Bundle.main.bundleURL
        for _ in 0..<4 {
            parent = parent.deletingLastPathComponent()
            roots.append(parent.appendingPathComponent("Contents/Resources", isDirectory: true))
        }

        for root in roots {
            if let bundle = Bundle(url: root.appendingPathComponent(bundleName)) {
                return bundle
            }
        }
        return Bundle.main
    }()

    public func string(_ key: StaticString, defaultValue: String) -> String {
        String(
            localized: key,
            defaultValue: String.LocalizationValue(stringLiteral: defaultValue),
            bundle: Self.resourceBundle
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

private final class BundleToken {}
