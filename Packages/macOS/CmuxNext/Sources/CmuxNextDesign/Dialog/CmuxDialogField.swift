import Foundation

/// An input in the dialog. Every field has an id; its value comes back in
/// `CmuxDialogAnswer.values`.
public nonisolated enum CmuxDialogField: Equatable, Sendable {
    /// One line of text; `secure` hides it (passwords).
    case text(id: String, label: String?, initial: String, placeholder: String?, secure: Bool)
    /// One of `options` (label, value).
    case choice(id: String, label: String?, options: [CmuxDialogOption], selected: String?)
    /// A check box ("Don't ask again").
    case check(id: String, title: String, on: Bool)
    /// Read-only text the user should see before answering (a paste preview).
    case preview(String)

    public var id: String? {
        switch self {
        case .text(let id, _, _, _, _), .choice(let id, _, _, _), .check(let id, _, _): id
        case .preview: nil
        }
    }

    public static func text(_ id: String, initial: String = "", label: String? = nil, placeholder: String? = nil) -> CmuxDialogField {
        .text(id: id, label: label, initial: initial, placeholder: placeholder, secure: false)
    }
}

public nonisolated struct CmuxDialogOption: Equatable, Sendable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public nonisolated enum CmuxDialogValue: Equatable, Sendable {
    case text(String)
    case bool(Bool)

    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}
