import Foundation

/// A toast's detail as its Details shows it: a known error code in a raw reason ("cannot copy the
/// build to the machine: fs.no_space: no space left on the device") becomes plain words ("The
/// machine is out of disk space."), and the code stays as secondary text to copy into a bug. A
/// detail with no known code, or of several lines (one per machine), stays as it came. Pure.
///
/// Leo, 2026-11-01, on the expanded "Couldn't update" toast that showed the raw reason with
/// `fs.no_space` in it: "ok tho the details toast doesnt look very good".
public nonisolated struct CmuxToastDetailCopy: Equatable, Sendable {
    /// What the toast shows as the detail: plain words, or the raw detail.
    public var text: String
    /// The code the plain words stand for; nil when ``text`` is the raw detail.
    public var code: String?

    public init(text: String, code: String? = nil) {
        self.text = text
        self.code = code
    }

    /// The plain words of `detail`'s first known code, with the code; for an `fs.*` code this map does not know, a
    /// plain line that the file operation failed, with the code; the raw detail when it names none, or has several
    /// lines (each its own reason, which one sentence would hide).
    public static func plain(_ detail: String) -> CmuxToastDetailCopy {
        guard !detail.contains(where: \.isNewline) else { return CmuxToastDetailCopy(text: detail) }
        let found = codes(in: detail)
        if let code = found.first(where: { words($0) != nil }), let words = words(code) {
            return CmuxToastDetailCopy(text: words, code: code)
        }
        if let code = found.first(where: { $0.hasPrefix("fs.") && $0.count > 3 }) {
            return CmuxToastDetailCopy(text: fileFailed, code: code)
        }
        return CmuxToastDetailCopy(text: detail)
    }

    /// The line for an `fs.*` code with no words of its own (a code the daemon added later).
    public static var fileFailed: String {
        String(localized: "toast.detail.fileFailed", defaultValue: "The machine couldn't finish the file operation.", bundle: .module)
    }

    /// The codes this map knows, in plain words; nil for any other. The codes are the daemon's
    /// `fs.*` refusals (cmux-tui `fs_ops/error.rs`, acpmux `hand/mod.rs` for `fs.permission` and
    /// `fs.io`) and the sync CLI's `disk_full`.
    public static func words(_ code: String) -> String? {
        switch code {
        case "fs.no_space", "disk_full":
            String(localized: "toast.detail.noSpace", defaultValue: "The machine is out of disk space.", bundle: .module)
        case "fs.read_only":
            String(localized: "toast.detail.readOnly", defaultValue: "The machine's disk is read-only.", bundle: .module)
        case "fs.permission_denied", "fs.permission":
            String(localized: "toast.detail.permissionDenied", defaultValue: "The machine didn't allow access to that location.",
                   bundle: .module)
        case "fs.too_large":
            String(localized: "toast.detail.tooLarge", defaultValue: "The file is too large for the machine.", bundle: .module)
        case "fs.not_found":
            String(localized: "toast.detail.notFound", defaultValue: "That file or folder isn't on the machine anymore.", bundle: .module)
        case "fs.exists":
            String(localized: "toast.detail.exists", defaultValue: "An item with that name already exists on the machine.", bundle: .module)
        case "fs.not_a_directory":
            String(localized: "toast.detail.notADirectory", defaultValue: "That path is a file, not a folder.", bundle: .module)
        case "fs.io":
            String(localized: "toast.detail.io", defaultValue: "The machine couldn't read or write the file.", bundle: .module)
        case "fs.revision_mismatch":
            String(localized: "toast.detail.revisionMismatch",
                   defaultValue: "The file changed on the machine after it was opened. Reload it, then try again.", bundle: .module)
        default:
            nil
        }
    }

    /// The code line under the plain words ("Error code: fs.no_space").
    public static func codeLine(_ code: String) -> String {
        String(format: String(localized: "toast.detail.errorCode", defaultValue: "Error code: %@", bundle: .module), code)
    }

    /// The code-shaped words of `detail` in order: runs of lowercase letters, digits, `_` and `.`,
    /// with no leading or trailing dot ("fs.no_space" out of "...: fs.no_space: ...").
    static func codes(in detail: String) -> [String] {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        return detail.split(whereSeparator: { !allowed.contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }
}
