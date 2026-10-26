#if DEBUG || CMUX_BENCH_HOOKS
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

extension OracleValue {
    /// `sha256:<hex>` of `text`'s UTF-8 bytes, the schema's `derive: sha256`: the one form a facet records private
    /// text in (a title, a draft), so the text itself never reaches a snapshot.
    public static func sha256(of text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
