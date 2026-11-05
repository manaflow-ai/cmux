public import AppKit
import os

/// The person's new terminals' claims on their windows' keyboards (ported from cp/dogfood-v2-2-12-opt 23248fdeba4a and
/// its review fixes 2be9a0cc33a1, a4c01b0b4036, 80723559628f). Terminal input must never reach an agent, whatever the
/// timing (dogfood v2.2.3: the keys typed for a new terminal asked for over Home went into Home's Chief message box, and
/// Return sent a shell command to the Chief as a message).
///
/// The person's own new workspace with a terminal claims its window's keyboard from the request until the person's next
/// intent in that window: a click, Escape, a focus or selection move of theirs (mouse, keyboard, palette), another of
/// their actions; or until the window shows the workspace. Never by a timeout, and never by automation (a script's or the
/// CLI's focus move or intent). While a claim holds, no primary input takes the keyboard by itself, and once no creation
/// hold keeps the keys (the terminal never showed), every key that runs no binding is kept from the window (``keeps(_:chordPending:runsBinding:)``).
@MainActor
public final class CreationKeyboardClaims {
    private final class Claim {
        weak var window: NSWindow?
        /// The workspace the create made (nil until its reply, or when it failed).
        var workspace: String?
        /// The timestamp of the person's input that asked for it (a click on a New Workspace button, its key): that
        /// input's own end does not end the claim it made.
        let inputTimestamp: TimeInterval?
        /// The hold of the create that made it: only that create's reply names its workspace.
        let ticket: CreationInputBuffer.Ticket
        /// The window's count of the person's own focus moves when it was made.
        let intents: UInt64
        /// The keys kept from the window while it held (the terminal never showed), logged when it ends.
        var kept = 0

        init(window: NSWindow, inputTimestamp: TimeInterval?, ticket: CreationInputBuffer.Ticket, intents: UInt64) {
            (self.window, self.inputTimestamp, self.ticket, self.intents) = (window, inputTimestamp, ticket, intents)
        }
    }

    private var claims: [Int: Claim] = [:] {
        // A claim that kept keys says so when it ends (no toast: the person's next intent ended it, or the terminal showed).
        willSet {
            for (number, claim) in claims where claim.kept > 0 && newValue[number] !== claim {
                Self.logger.notice("keyboard claim of window \(number, privacy: .public) ended; it kept \(claim.kept, privacy: .public) key(s) from the window")
            }
        }
    }
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    public init() {}

    public var isEmpty: Bool { claims.isEmpty }

    /// The person's new workspace behind `ticket` claims `window`'s keyboard, asked for by the input of timestamp `input`,
    /// while the window's own focus moves of the person number `intents`.
    public func claim(_ window: NSWindow, ticket: CreationInputBuffer.Ticket, input: TimeInterval?, intents: UInt64) {
        claims[window.windowNumber] = Claim(window: window, inputTimestamp: input, ticket: ticket, intents: intents)
    }

    /// The create behind `ticket` made `workspace`: the claim ends once the window shows it (``holds(in:shows:intents:lastInput:)``).
    public func made(_ workspace: String, by ticket: CreationInputBuffer.Ticket, in window: NSWindow) {
        guard let claim = claims[window.windowNumber], claim.ticket == ticket else { return }
        claim.workspace = workspace
    }

    /// The person acted in the window numbered `window` (a click after its dispatch, one of their actions), answering the
    /// input of timestamp `input`: a claim there ends. The input that asked for the claim does not end it. True when one ended.
    @discardableResult
    public func personActed(inWindow window: Int, input: TimeInterval?) -> Bool {
        guard let claim = claims[window] else { return false }
        if let input, input == claim.inputTimestamp { return false }
        claims[window] = nil
        return true
    }

    /// Ends the claim of the window numbered `window`.
    public func end(inWindow window: Int) { claims[window] = nil }

    /// Whether `window`'s claim holds while it shows workspace `shown` and the person made `intents` focus or selection
    /// moves of their own there (mouse, keyboard, palette), the last one answering the input of timestamp `lastInput`: the
    /// window does not show the claimed workspace yet, and the person made no such move since the claim (other than one
    /// answering the input that asked for it). A claim that ended is removed here.
    public func holds(in window: NSWindow, shows shown: String?, intents: UInt64, lastInput: TimeInterval?) -> Bool {
        let number = window.windowNumber
        guard let claim = claims[number] else { return false }
        let moved = intents != claim.intents && (lastInput == nil || lastInput != claim.inputTimestamp)
        guard claim.window === window, !moved, claim.workspace == nil || claim.workspace != shown else {
            claims[number] = nil
            return false
        }
        return true
    }

    /// A key of `window` while its claim holds and no creation hold keeps it (the terminal never showed): false when it
    /// goes on, true when it is kept from the window; nil for Escape, which ends the claim and goes on (the caller applies
    /// the window's focus again). A key that runs a binding (`runsBinding`: Ctrl-Tab, a leader, Cmd-T) or the next key of
    /// a pending chord goes on: the action it runs is the person's next intent. Every other key (text, Return, Cmd-V) is
    /// kept: the terminal it was typed for is not there, and no other input (Home's message box) takes it.
    public func keeps(_ event: NSEvent, in window: NSWindow, chordPending: Bool, runsBinding: () -> Bool) -> Bool? {
        if event.keyCode == 53 { // Escape
            claims[window.windowNumber] = nil
            return nil
        }
        guard !chordPending, !runsBinding() else { return false }
        if let claim = claims[window.windowNumber] { claim.kept += 1 }
        return true
    }
}
