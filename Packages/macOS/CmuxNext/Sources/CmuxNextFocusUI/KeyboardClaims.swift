public import AppKit

/// The person's new terminal's claim on a window's keyboard, by window number (dogfood v2.2.3: Home's Chief message box
/// took the keys typed for a new terminal and sent a shell command to the Chief as a message; terminal input must never
/// reach an agent). A claim starts when the person asks for a new workspace with a terminal shown in the window they type
/// in (`CreationInputCoordinator.beginWorkspace`), and ends at the person's next intent there (a click, Escape, a focus
/// move of theirs, another of their actions), when the window shows the workspace its create made, or when the window
/// closes. Never by a timeout, and never by automation (a script's focus move or intent).
@MainActor
public final class KeyboardClaims {
    private final class Claim {
        weak var window: NSWindow?
        /// The workspace the create made (nil until its reply, or when it failed).
        var workspace: String?
        /// The timestamp of the person's input that asked for it (a click on a New Workspace button): that input's own
        /// end does not end the claim it made.
        let inputTimestamp: TimeInterval?
        /// The hold of the create that made it: only that create's reply names its workspace.
        let ticket: CreationInputBuffer.Ticket

        init(window: NSWindow, inputTimestamp: TimeInterval?, ticket: CreationInputBuffer.Ticket) {
            self.window = window
            self.inputTimestamp = inputTimestamp
            self.ticket = ticket
        }
    }

    private var claims: [Int: Claim] = [:]

    public init() {}

    /// No window has a claim: a key or an intent has nothing to end or keep.
    public var isEmpty: Bool { claims.isEmpty }

    /// `window`'s keyboard is now the new terminal of the create behind `ticket`, asked for by the input at
    /// `inputTimestamp` (nil: no input event, a menu item run by the system). A claim made earlier there is replaced.
    public func begin(in window: NSWindow, inputTimestamp: TimeInterval?, ticket: CreationInputBuffer.Ticket) {
        claims[window.windowNumber] = Claim(window: window, inputTimestamp: inputTimestamp, ticket: ticket)
    }

    /// `window` closed: its claim goes with it.
    public func end(in window: NSWindow) {
        claims[window.windowNumber] = nil
    }

    /// The person acted in `window` (its shell window), answering the input at `inputTimestamp`: the claim there ends,
    /// unless that input is the one that asked for it (the click or key of New Workspace).
    public func personActed(in window: NSWindow, inputTimestamp: TimeInterval?) {
        let number = window.windowNumber
        if let inputTimestamp, let made = claims[number]?.inputTimestamp, made == inputTimestamp { return }
        claims[number] = nil
    }

    /// The create behind `ticket` made `workspace`. False when `window`'s claim is not that create's (a later press
    /// replaced it): the reply then names nothing.
    public func noteMade(_ workspace: String, by ticket: CreationInputBuffer.Ticket, in window: NSWindow) -> Bool {
        guard let claim = claims[window.windowNumber], claim.ticket == ticket else { return false }
        claim.workspace = workspace
        return true
    }

    /// Whether `window`'s claim holds now: the window is open (`isOpen`) and does not show the workspace the claim's
    /// create made (`shown`, the workspace it shows). A claim that ended is removed here.
    public func holds(in window: NSWindow, isOpen: Bool, shown: String?) -> Bool {
        let number = window.windowNumber
        guard let claim = claims[number] else { return false }
        guard isOpen, claim.window === window, claim.workspace == nil || claim.workspace != shown else {
            claims[number] = nil
            return false
        }
        return true
    }

    /// Whether `window` has a claim recorded now, ended or not (tests, `debug.focus`).
    public func isRecorded(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return claims[window.windowNumber] != nil
    }
}
