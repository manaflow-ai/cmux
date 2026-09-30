import CryptoKit
import Foundation

/// The shim's ABI identity: the SHA-256 of `CEF/Shim/cmux_cef_shim.h`.
///
/// This target bundles the header as a resource, so the identity is the
/// header this Swift code was built with. `build-cef-shim.sh` hashes the same
/// file into the shim (`cmux_shim_abi_id`). Any edit to the header changes
/// both, and a merge of two edits gives a third identity, so there is no
/// number to bump. `short` is for logs.
nonisolated enum CEFShimABI {
    static let resourceName = "cmux_cef_shim"

    /// The bundled header's identity; nil when the resource is missing.
    static let expected: String? = Bundle.module
        .url(forResource: resourceName, withExtension: "h")
        .flatMap { try? identity(of: Data(contentsOf: $0)) }

    /// 64 lowercase hex digits, as `shasum -a 256` prints them.
    static func identity(of header: Data) -> String {
        SHA256.hash(data: header).map { String(format: "%02x", $0) }.joined()
    }

    static func short(_ identity: String) -> String {
        String(identity.prefix(12))
    }
}
