public import Foundation

/// An acpmux permission request (`request` of `_acpmux/permission_pending`) as the app reads it
/// for the person: the feed bridge and approval banners share these (``AcpmuxPermissionPrompt``).
nonisolated public extension Dictionary where Key == String, Value == Any {
    /// sha256 of the request's canonical JSON (sorted keys): an answer counts only for the same one.
    var acpmuxDigest: String { AcpmuxPermissionPrompt.digest(self) }
    /// A tool input's `command` as a shell would read it (an argv array shell-quoted).
    var acpmuxShownCommand: String? { AcpmuxPermissionPrompt.shownCommand(self["command"]) }
    /// A tool input's other fields, scrubbed and cut, and whether anything was cut or dropped.
    var acpmuxInputSummary: (fields: [String: String], truncated: Bool)? { AcpmuxPermissionPrompt.inputSummary(self) }
    /// True when the request is a question an agent asks a person, never a tool permission.
    var acpmuxIsQuestion: Bool { AcpmuxPermissionPrompt.isQuestion(self) }
    /// The request's normalized question (`toolCall._meta.acpmux.question`), when it has one.
    var acpmuxQuestion: [String: Any]? { AcpmuxPermissionPrompt.question(self) }
}

nonisolated public extension Array where Element == [String: Any] {
    /// The option of these offered ones an allow once (`allow`) or a deny maps to; nil when not
    /// offered exactly once.
    func acpmuxOption(allow: Bool) -> String? { AcpmuxPermissionPrompt.option(allow: allow, offered: self) }
}

nonisolated public extension String {
    /// Bidi controls and zero-width characters shown as `<U+XXXX>`.
    var acpmuxVisible: String { AcpmuxPermissionPrompt.visible(self) }
    /// At most `limit` characters, the last one an ellipsis when cut.
    func acpmuxCut(_ limit: Int) -> String { AcpmuxPermissionPrompt.cut(self, limit) }
    /// Known secret shapes replaced with `[redacted]` (``FeedSecretScrubber``).
    var secretsScrubbed: String { FeedSecretScrubber.scrub(self) }
    /// ``secretsScrubbed`` of the first 16 KiB characters (unbounded program output).
    var secretsScrubbedPrefix: String { FeedSecretScrubber.scrubPrefix(self) }
}

nonisolated public extension Data {
    /// One JSON-RPC request line to acpmux.
    init(acpmuxRequest id: Int, method: String, params: [String: Any]) {
        self = AcpmuxPermissionPrompt.frame(id: id, method: method, params: params)
    }
}
