public import Foundation

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
    /// A read-only code to compare letter by letter (a device key fingerprint): its caption, then the
    /// code in monospaced digits on an inset well, selectable so it can be copied. Each line of `text`
    /// draws as one line.
    case code(label: String?, text: String)
    /// A line to copy (a command to paste on another machine): its caption, the text monospaced on the code's well,
    /// and a small button at its end that presses `id` (the host copies; the dialog stays).
    case copyLine(id: String, label: String?, text: String, button: String)
    /// A short code to type on another machine: large, with its QR image beside it, a live countdown to when it
    /// stops working, and its notes (``CmuxDialogPairingCode``).
    case pairingCode(CmuxDialogPairingCode)
    /// Work under way: a small spinner and what it waits for.
    case progress(String)
    /// A short caption among the fields (a warning, a hint); `danger` draws it in the danger ink.
    case note(String, danger: Bool)
    /// The steps of a run, one row each: its state's glyph, its name, what it found and how to fix it.
    case steps([CmuxDialogStep])

    public var id: String? {
        switch self {
        case .text(let id, _, _, _, _), .choice(let id, _, _, _), .check(let id, _, _): id
        case .preview, .code, .copyLine, .pairingCode, .progress, .note, .steps: nil
        }
    }

    /// The ids of the in-field buttons (a copy line's Copy, a pairing code's Copy): pressed like a button, they
    /// answer nothing and keep the dialog up.
    public var actionIDs: [String] {
        switch self {
        case .copyLine(let id, _, _, _): [id]
        case .pairingCode(let code): code.copyID.map { [$0] } ?? []
        default: []
        }
    }

    public static func text(_ id: String, initial: String = "", label: String? = nil, placeholder: String? = nil) -> CmuxDialogField {
        .text(id: id, label: label, initial: initial, placeholder: placeholder, secure: false)
    }
}

/// A pairing code as a dialog shows it (``CmuxDialogField/pairingCode(_:)``).
public nonisolated struct CmuxDialogPairingCode: Equatable, Sendable {
    public var code: String
    /// The QR of what a phone scans (PNG data); nil draws none.
    public var image: Data?
    /// What the QR is, for VoiceOver ("Scan with the cmux app on iPhone").
    public var imageLabel: String
    /// When the code stops working; the card counts down to it, in the attention ink in its last minute.
    public var expiresAt: Date?
    /// The countdown's words, `%@` for the time left ("Expires in %@").
    public var expiresFormat: String
    /// Short notes under the countdown ("Works once", "Scan the code with the cmux app").
    public var notes: [String]
    /// The id of the Copy button under the code; nil draws none.
    public var copyID: String?
    public var copyTitle: String

    public init(code: String, image: Data? = nil, imageLabel: String = "", expiresAt: Date? = nil, expiresFormat: String = "%@",
                notes: [String] = [], copyID: String? = nil, copyTitle: String = "") {
        self.code = code
        self.image = image
        self.imageLabel = imageLabel
        self.expiresAt = expiresAt
        self.expiresFormat = expiresFormat
        self.notes = notes
        self.copyID = copyID
        self.copyTitle = copyTitle
    }

    /// `9:41` for the seconds left at `now`, rounded up, never below zero.
    public static func clock(until date: Date, now: Date) -> String {
        let left = max(0, Int((date.timeIntervalSince(now)).rounded(.up)))
        return String(format: "%d:%02d", left / 60, left % 60)
    }
}

/// One step of a run as a dialog lists it (``CmuxDialogField/steps(_:)``).
public nonisolated struct CmuxDialogStep: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, running, done, warning, failed, skipped }

    public var title: String
    public var state: State
    public var detail: String
    /// A sentence for the person; never a command cmux runs for them.
    public var fix: String?

    public init(title: String, state: State, detail: String = "", fix: String? = nil) {
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
    }
}

public nonisolated struct CmuxDialogOption: Equatable, Sendable {
    public var label: String
    public var value: String
    /// False lists the option greyed out: it cannot be picked.
    public var isEnabled = true
    public init(label: String, value: String, isEnabled: Bool = true) {
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
    }
}

public nonisolated enum CmuxDialogValue: Equatable, Sendable {
    case text(String)
    case bool(Bool)

    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}
