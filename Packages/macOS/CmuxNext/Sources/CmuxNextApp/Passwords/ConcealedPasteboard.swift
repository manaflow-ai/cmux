import AppKit
import CmuxNextBrowserImport
import CmuxNextWakeups

/// The pasteboard calls ``ConcealedPasteboard`` makes (the system pasteboard in the app; a
/// recording fake in tests, which run without a pasteboard server).
@MainActor
protocol PasswordPasteboard: AnyObject {
    var changeCount: Int { get }
    /// Replaces the contents with `text`, marked with `markers` (empty data per type).
    func write(_ text: String, markers: [NSPasteboard.PasteboardType])
    func clearContents()
}

/// The system pasteboard.
@MainActor
final class SystemPasswordPasteboard: PasswordPasteboard {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func write(_ text: String, markers: [NSPasteboard.PasteboardType]) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers { item.setData(Data(), forType: marker) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func clearContents() {
        pasteboard.clearContents()
    }
}

/// Puts a password on the pasteboard the way password managers do: marked concealed and
/// transient (nspasteboard.org types, so clipboard managers skip it) and cleared after
/// ``clearAfter`` unless something else was copied meanwhile. The deadline is a `background`
/// ``MainDeadline`` on the injected scheduler: nobody watches the clear happen.
@MainActor
final class ConcealedPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// How long a copied password stays (no setting yet; passwords.md 1.4 asks for one).
    static let defaultClearAfter: Duration = .seconds(90)

    private let pasteboard: any PasswordPasteboard
    private let clearTimer: MainDeadline
    let clearAfter: Duration
    /// Runs after each deadline, cleared or not (tests await it).
    var onDeadline: (@MainActor () -> Void)?

    init(pasteboard: (any PasswordPasteboard)? = nil, deadlines: MainDeadlineScheduler,
         clearAfter: Duration = ConcealedPasteboard.defaultClearAfter) {
        self.pasteboard = pasteboard ?? SystemPasswordPasteboard()
        self.clearAfter = clearAfter
        clearTimer = MainDeadline(owner: "App.passwords.clearPasteboard", workClass: .background, scheduler: deadlines)
    }

    func write(_ secret: SecretBytes) {
        // SAFETY: the bytes view is SecretBytes' own locked buffer, valid for the closure; the String copies
        // the bytes out before it returns and the view does not escape.
        let text = unsafe secret.withUnsafeBytes { unsafe String(decoding: $0, as: UTF8.self) }
        pasteboard.write(text, markers: [Self.concealedType, Self.transientType])
        let written = pasteboard.changeCount
        clearTimer.schedule(after: clearAfter) { [weak self] in
            self?.clear(ifStill: written)
            self?.onDeadline?()
        }
    }

    /// Clears the pasteboard when it still holds the password written at `changeCount`.
    func clear(ifStill changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
    }
}
