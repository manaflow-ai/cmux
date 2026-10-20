public import Foundation

/// The Chromium runtime pack an app build was made for, read from the app's
/// `Contents/Resources/cef-runtime.json`.
///
/// The pin sits inside the app's code signature, so its `sha256` is as trusted
/// as the app itself: a downloaded pack is installed only when its bytes hash
/// to it (plans/cmux-next/bundle-size-DESIGN.md section 6.2). Release signing
/// writes the file (`scripts/cmux-next/cef-runtime-pack.sh`); builds that embed
/// Chromium have no pin.
///
/// ```json
/// {"schema": 1, "key": "0123456789abcdef", "cef": "154.0.28",
///  "chromium": "154.0.8037.58", "shim_abi": "…", "sha256": "…",
///  "size": 107000000, "url": "https://files-next.cmux.com/cef-runtime/…",
///  "team_id": "ABCDE12345", "folder": "cmux NIGHTLY Chromium"}
/// ```
public struct ChromiumRuntimePin: Codable, Sendable, Equatable {
    /// The file name of the pin in the app's resources.
    public static let resourceName = "cef-runtime.json"

    /// The pin format; this build reads schema 1.
    public var schema: Int
    /// The pack key: 16 lowercase hex characters, also the install folder name.
    public var key: String
    /// The CEF version in the pack, for diagnostics.
    public var cef: String
    /// The Chromium version in the pack, for diagnostics.
    public var chromium: String
    /// The shim ABI identity. Two packs with the same ABI, folder and team
    /// are interchangeable for one launch (``ChromiumRuntimeStore/select(for:)``).
    public var shimABI: String
    /// The sha256 of the whole pack file, 64 lowercase hex characters.
    public var sha256: String
    /// The size of the pack file in bytes.
    public var size: Int64
    /// Where the pack is downloaded from (https, or http to a loopback host).
    public var url: URL
    /// The Developer ID team that signed the pack's code, nil for ad hoc
    /// (dev) packs, which are checked by hash only.
    public var teamID: String?
    /// The runtime folder's name inside the pack, for example
    /// `cmux NIGHTLY Chromium` (a plain folder, never an `.app`).
    public var folder: String

    enum CodingKeys: String, CodingKey {
        case schema, key, cef, chromium, sha256, size, url, folder
        case shimABI = "shim_abi"
        case teamID = "team_id"
    }

    /// Creates a pin; ``validated()`` checks it.
    public init(schema: Int = 1, key: String, cef: String, chromium: String, shimABI: String, sha256: String,
                size: Int64, url: URL, teamID: String?, folder: String) {
        self.schema = schema
        self.key = key
        self.cef = cef
        self.chromium = chromium
        self.shimABI = shimABI
        self.sha256 = sha256
        self.size = size
        self.url = url
        self.teamID = teamID
        self.folder = folder
    }

    /// Why a pin cannot be used.
    public enum Invalid: Error, Equatable, Sendable {
        case schema(Int)
        case key
        case sha256
        case size
        case url
        case folder
        case teamID
    }

    /// Decodes and validates a pin.
    ///
    /// - Parameter data: The JSON of `cef-runtime.json`.
    /// - Returns: The validated pin.
    /// - Throws: `DecodingError` for malformed JSON, ``Invalid`` for a bad value.
    public static func decode(_ data: Data) throws -> ChromiumRuntimePin {
        try JSONDecoder().decode(ChromiumRuntimePin.self, from: data).validated()
    }

    /// The pin in `resourcesDirectory`, nil when the app has none or it is invalid.
    ///
    /// - Parameter resourcesDirectory: The app's `Contents/Resources` folder.
    public static func bundled(in resourcesDirectory: URL) -> ChromiumRuntimePin? {
        guard let data = try? Data(contentsOf: resourcesDirectory.appending(path: resourceName)) else { return nil }
        return try? decode(data)
    }

    /// The pin when every value is well formed.
    ///
    /// - Throws: ``Invalid`` naming the first bad value.
    public func validated() throws(Invalid) -> ChromiumRuntimePin {
        guard schema == 1 else { throw .schema(schema) }
        guard key.count == 16, key.allSatisfy(\.isLowercaseHex) else { throw .key }
        guard sha256.count == 64, sha256.allSatisfy(\.isLowercaseHex) else { throw .sha256 }
        guard size > 0 else { throw .size }
        guard Self.isAllowedURL(url) else { throw .url }
        guard !folder.isEmpty, folder.count <= 128, !folder.contains("/"), !folder.hasPrefix("."), !folder.hasSuffix(".app") else {
            throw .folder
        }
        if let teamID, teamID.isEmpty || !teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            throw .teamID
        }
        return self
    }

    /// https anywhere; http only to a loopback host (local tests and dogfood).
    static func isAllowedURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return url.host() != nil
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "")
        default: return false
        }
    }
}

extension Character {
    var isLowercaseHex: Bool { ("0"..."9").contains(self) || ("a"..."f").contains(self) }
}
