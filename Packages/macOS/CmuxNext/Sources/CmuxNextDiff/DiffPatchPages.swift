import CmuxNextSettings
import CmuxNextPages
import Foundation

/// Joins bounded raw bytes only while the daemon proves one immutable patch.
/// The loop stops on complete, cancellation, or a malformed/changed page.
nonisolated enum DiffPatchPages {
    /// The most bytes one side of a file may have, as the local viewer's sidecar
    /// (`Native/DiffSidecar` `MAX_FILE_SIDE_BYTES`): a larger file answers `tooLarge`.
    static let maximumSideBytes = 2 * 1024 * 1024
    /// The most bytes of one file's patch a read joins: its two sides at the side limit, where a
    /// side of empty lines doubles in the patch (each line gets its `+`, `-` or ` `), and the
    /// headers. A larger patch is a file the local viewer could not show either.
    static let maximumFilePatchBytes = 4 * maximumSideBytes + maximumSideBytes / 2

    /// The joined patch, or nil when it is larger than ``maximumFilePatchBytes`` (no page past
    /// the first is read then).
    @concurrent static func read(_ page: @MainActor @Sendable (UInt64, String?) async throws -> JSONValue) async throws -> Data? {
        var offset: UInt64 = 0
        var revision: String?
        var total: UInt64?
        var data = Data()
        // concurrency-allow: @concurrent byte processing; each page awaits the main-actor transport, rejects no progress and ends at the fixed total or cancellation.
        // wakeup-allow: demand-driven finite patch read, awaiting each RPC; no polling or background timer, and cancelled with the owning request.
        repeat {
            try Task.checkCancellation()
            let reply = try await page(offset, revision)
            try Task.checkCancellation()
            guard let value = reply["patch_page"],
                  let start = decimal(value["offset"]), start == offset,
                  let next = decimal(value["next_offset"]),
                  let length = decimal(value["total_bytes"]),
                  length <= UInt64(DiffPatchResolver.maximumPatchBytes),
                  let identity = value["revision"]?.stringValue, identity.utf8.count == 64,
                  identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  revision == nil || revision == identity,
                  total == nil || total == length,
                  let encoded = value["data_base64"]?.stringValue,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 512 * 1024,
                  next >= offset, next - offset == UInt64(bytes.count), next <= length,
                  let complete = value["complete"]?.boolValue,
                  complete == (next == length), complete || next > offset else {
                throw PageError(code: "remotePatchChanged", message: "The remote patch changed or could not be read completely. Reload the diff.")
            }
            if length > UInt64(maximumFilePatchBytes) { return nil }
            data.append(bytes)
            offset = next
            revision = identity
            total = length
        } while offset < (total ?? 0)
        return data
    }

    @concurrent static func text(_ bytes: Data) async -> String? {
        String(data: bytes, encoding: .utf8)
    }

    private static func decimal(_ value: JSONValue?) -> UInt64? {
        guard let text = value?.stringValue, let number = UInt64(text), String(number) == text else { return nil }
        return number
    }
}
