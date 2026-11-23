import Foundation
import os

/// Strings of the sidebar document path. The text of a refused or failed change is Rust's, beside the reducer
/// (cmux-layout-reducer `sidebar_doc::change_failure_text`, FFI op `sidebar_change_failure`): one copy per code.
nonisolated enum SidebarDocStrings {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.doc")

    static var move: String { String(localized: "sidebar.doc.move", defaultValue: "Move", bundle: .localizedModule) }

    /// The document is not served yet (`unavailable`).
    static var unavailable: String { refused("unavailable") }

    /// Why a change was refused or failed: a reducer refusal code (`cross_machine`, `nesting`, ...) or a failure
    /// kind (`no_answer`, `unavailable`, `failed`).
    static func refused(_ code: String) -> String {
        struct Request: Encodable { var code: String }
        struct Reply: Decodable { var text: String }
        if let reply = RustSidebarClient.call("sidebar_change_failure", Request(code: code), as: Reply.self) { return reply.text }
        // The app FFI did not answer (a build pinned before the op): the code itself, never a vague sentence.
        logger.fault("sidebar_change_failure gave no text for \(code, privacy: .public)")
        return code
    }

    /// The code of a failed change: the reducer's (the mirror's or the daemon's refusal), else `failed`.
    static func code(_ error: any Error) -> String {
        (error as? SidebarMirror.Refusal)?.code ?? "failed"
    }
}

extension SidebarDocStore {
    /// The undo title of a drag or keyboard move.
    public static var moveTitle: String { SidebarDocStrings.move }
}
