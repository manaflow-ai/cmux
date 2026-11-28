import Foundation

/// Where a terminal that asks for the clipboard runs.
public enum ClipboardReadHostKind: String, Sendable, Hashable {
    case local, remote, cloud, unknown
}

/// `ClipboardReadHost` is generated from the schema's `TerminalClipboardHost` (swift_app/bindings.json, Terminals family).
