/// The shell input the cursor is editing, as Ghostty reports it.
///
/// Offsets count caret stops: input cells holding a character, with
/// wide-character spacers skipped. Each stop is one Left/Right arrow step for
/// a line editor such as zle or readline, so a selection over stops can be
/// turned into cursor motion plus deletion without the shell knowing anything
/// about selection.
public struct TerminalPromptInputSnapshot: Equatable, Sendable {
    /// Caret stops in the input.
    public let length: Int

    /// Caret stops before the cursor, in `0...length`.
    public let caret: Int

    /// The selected stops, present only when the terminal selection lies
    /// wholly within the input.
    public let selection: Range<Int>?

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - length: Caret stops in the input.
    ///   - caret: Caret stops before the cursor.
    ///   - selection: The selected stops, or `nil` when the terminal selection
    ///     is absent or reaches outside the input.
    public init(length: Int, caret: Int, selection: Range<Int>?) {
        self.length = length
        self.caret = caret
        self.selection = selection
    }
}

/// A prompt selection with the direction a text field gives it.
///
/// Terminal selections have no direction, so cmux keeps the anchor itself.
/// `anchor` stays put while Shift+arrow moves `head`.
public struct TerminalPromptSelection: Equatable, Sendable {
    /// The end that stays fixed while the selection is extended.
    public let anchor: Int

    /// The end that Shift+arrow moves.
    public let head: Int

    /// Creates a directed selection.
    ///
    /// - Parameters:
    ///   - anchor: The fixed end.
    ///   - head: The moving end.
    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    /// The selected caret stops.
    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
}

/// Which way a Shift+arrow extension moves the selection head.
public enum TerminalPromptSelectionDirection: Equatable, Sendable {
    /// Toward the start of the input.
    case backward
    /// Toward the end of the input.
    case forward
}

/// How far a Shift+arrow extension moves the selection head.
public enum TerminalPromptSelectionGranularity: Equatable, Sendable {
    /// One caret stop, as Shift+Left/Right.
    case character
    /// To the start or end of the input, as Cmd+Shift+Left/Right.
    case inputBoundary
}

/// A text-field gesture the prompt selection layer may own.
public enum TerminalPromptSelectionIntent: Equatable, Sendable {
    /// Cmd+A, Edit > Select All.
    case selectAll
    /// Shift-extended caret motion.
    case extend(TerminalPromptSelectionDirection, TerminalPromptSelectionGranularity)
    /// Cmd+X, Edit > Cut.
    case cut
    /// Plain Left/Right, which collapses a selection to that edge.
    case collapse(TerminalPromptSelectionDirection)
    /// Backspace or forward Delete.
    case delete
    /// A keystroke that inserts printable text.
    case insertText
}

/// Keystrokes that move the shell caret and delete the selected input.
///
/// The arrows run first, leaving the caret just after the selection, then
/// `deleteBackward` backspaces remove it. Backspace is used for both deletion
/// keys because every line editor binds it; forward delete is not universal.
///
/// This assumes an emacs-style keymap. In a vi command mode Backspace moves
/// instead of deleting, and a Right arrow at the end of a zsh buffer accepts
/// an autosuggestion, so an edit there does the wrong thing.
public struct TerminalPromptInputEdit: Equatable, Sendable {
    /// Left-arrow presses to send first.
    public let moveLeft: Int

    /// Right-arrow presses to send first.
    public let moveRight: Int

    /// Backspace presses to send after the arrows.
    public let deleteBackward: Int

    /// Creates an edit.
    ///
    /// - Parameters:
    ///   - moveLeft: Left-arrow presses.
    ///   - moveRight: Right-arrow presses.
    ///   - deleteBackward: Backspace presses.
    public init(moveLeft: Int, moveRight: Int, deleteBackward: Int) {
        self.moveLeft = moveLeft
        self.moveRight = moveRight
        self.deleteBackward = deleteBackward
    }

    /// The edit that removes `range` when the caret sits at `caret`.
    ///
    /// - Parameters:
    ///   - range: The caret stops to delete.
    ///   - caret: The current caret, in stops.
    /// - Returns: The arrow and backspace counts.
    public static func deleting(_ range: Range<Int>, caret: Int) -> TerminalPromptInputEdit {
        TerminalPromptInputEdit(
            moveLeft: max(0, caret - range.upperBound),
            moveRight: max(0, range.upperBound - caret),
            deleteBackward: range.count
        )
    }

    /// The edit that only moves the caret from `caret` to `target`.
    ///
    /// - Parameters:
    ///   - target: The caret stop to move to.
    ///   - caret: The current caret, in stops.
    /// - Returns: The arrow counts, with no deletion.
    public static func moving(to target: Int, caret: Int) -> TerminalPromptInputEdit {
        TerminalPromptInputEdit(
            moveLeft: max(0, caret - target),
            moveRight: max(0, target - caret),
            deleteBackward: 0
        )
    }
}

/// What the terminal view should do with a prompt selection intent.
public enum TerminalPromptSelectionAction: Equatable, Sendable {
    /// Not ours: deliver the event exactly as the terminal does today.
    case passThrough
    /// Ours, but nothing changes, such as Shift+Left at the start of input.
    case consume
    /// Select the given stops and remember the direction.
    case select(TerminalPromptSelection)
    /// Clear the selection; the extension collapsed it onto its anchor.
    ///
    /// The caller keeps the empty `collapsed` selection as its tracked state
    /// so the next Shift+arrow continues from there, and drops it on any
    /// other input.
    case clearSelection(collapsed: TerminalPromptSelection)
    /// Clear the selection and apply `edit`.
    ///
    /// When `copyFirst` is set the selection is copied before it is cleared
    /// (Cut). When `thenPassThrough` is set the original keystroke is still
    /// delivered afterward, so typed text replaces the selection.
    case edit(TerminalPromptInputEdit, copyFirst: Bool, thenPassThrough: Bool)
}

/// Resolves a text-field gesture against the shell input under the cursor.
///
/// A `nil` snapshot means Ghostty reported no editable prompt: no shell
/// integration, a command running, or the alternate screen. Every intent then
/// passes through, so TUIs and bare shells behave exactly as they do today.
/// Cut, delete, and typing only act on a selection that lies wholly inside the
/// input; anything else passes through, which also means Cut never copies an
/// empty selection.
///
/// ```swift
/// let action = terminalPromptSelectionResolve(
///     intent: .selectAll,
///     snapshot: TerminalPromptInputSnapshot(length: 5, caret: 5, selection: nil),
///     tracked: nil
/// )
/// // action == .select(TerminalPromptSelection(anchor: 0, head: 5))
/// ```
///
/// - Parameters:
///   - intent: The gesture.
///   - snapshot: The input under the cursor, or `nil` when not at a prompt.
///   - tracked: The directed selection cmux last made, if any. It is trusted
///     only while it still matches the terminal's selection.
/// - Returns: The action to take.
public func terminalPromptSelectionResolve(
    intent: TerminalPromptSelectionIntent,
    snapshot: TerminalPromptInputSnapshot?,
    tracked: TerminalPromptSelection?
) -> TerminalPromptSelectionAction {
    guard let snapshot else { return .passThrough }
    let length = max(0, snapshot.length)
    let caret = min(max(0, snapshot.caret), length)
    let selection = snapshot.selection.flatMap { range -> Range<Int>? in
        let clamped = range.clamped(to: 0..<length)
        return clamped.isEmpty ? nil : clamped
    }

    switch intent {
    case .selectAll:
        // An empty prompt keeps today's select-all, which is still useful for
        // grabbing scrollback.
        guard length > 0 else { return .passThrough }
        return .select(TerminalPromptSelection(anchor: 0, head: length))

    case let .extend(direction, granularity):
        let current = terminalPromptSelectionCurrent(
            selection: selection,
            tracked: tracked,
            caret: caret,
            length: length,
            direction: direction
        )
        let head: Int
        switch (direction, granularity) {
        case (.backward, .character): head = max(0, current.head - 1)
        case (.forward, .character): head = min(length, current.head + 1)
        case (.backward, .inputBoundary): head = 0
        case (.forward, .inputBoundary): head = length
        }
        guard head != current.head else { return .consume }
        guard head != current.anchor else {
            return .clearSelection(collapsed: TerminalPromptSelection(anchor: head, head: head))
        }
        return .select(TerminalPromptSelection(anchor: current.anchor, head: head))

    case let .collapse(direction):
        guard let selection else { return .passThrough }
        let target = direction == .backward ? selection.lowerBound : selection.upperBound
        return .edit(.moving(to: target, caret: caret), copyFirst: false, thenPassThrough: false)

    case .cut, .delete, .insertText:
        guard let selection else { return .passThrough }
        return .edit(
            .deleting(selection, caret: caret),
            copyFirst: intent == .cut,
            thenPassThrough: intent == .insertText
        )
    }
}

/// The directed selection an extension starts from.
///
/// The tracked selection wins while it matches the terminal, including an
/// empty one left by a collapse. A selection cmux did not make (a mouse drag
/// inside the input) is extended from its far end in the direction of
/// travel. With neither, the caret is both anchor and head.
private func terminalPromptSelectionCurrent(
    selection: Range<Int>?,
    tracked: TerminalPromptSelection?,
    caret: Int,
    length: Int,
    direction: TerminalPromptSelectionDirection
) -> TerminalPromptSelection {
    guard let selection else {
        // Trust a collapse point only while it still lies inside the input.
        if let tracked, tracked.range.isEmpty, tracked.head <= length { return tracked }
        return TerminalPromptSelection(anchor: caret, head: caret)
    }
    if let tracked, tracked.range == selection { return tracked }
    switch direction {
    case .backward:
        return TerminalPromptSelection(anchor: selection.upperBound, head: selection.lowerBound)
    case .forward:
        return TerminalPromptSelection(anchor: selection.lowerBound, head: selection.upperBound)
    }
}

/// Maps a key-down event to a prompt selection intent.
///
/// Cmd+A and Cmd+X are not mapped here: they arrive as the Edit menu's Select
/// All and Cut actions. Control-bearing events never map, so Ctrl+C keeps
/// reaching the shell. Option+arrow and Option+Delete do not map;
/// word-wise selection needs the input text, which Ghostty does not export.
/// Option-typed text (German `@`, accented letters) does map to insertion.
///
/// Plain arrows and plain typing map too, but the resolver passes them
/// through unless a selection lies inside the input, so the caller should
/// consult it only while it holds a prompt selection.
///
/// This is pure and cheap so the key path can call it before doing any
/// terminal I/O.
///
/// - Parameters:
///   - keyCode: The virtual key code.
///   - modifiers: The event modifiers, already mapped off AppKit.
///   - producesText: Whether the event inserts printable text (not a control
///     character, not Return or Tab, not marked text). Must be `false` when
///     Option is acting as Alt (`macos-option-as-alt`), since the shell then
///     receives a Meta chord rather than text.
/// - Returns: The intent, or `nil` when the event is not one this layer owns.
public func terminalPromptSelectionIntent(
    keyCode: UInt16,
    modifiers: TerminalTextEditingModifiers,
    producesText: Bool
) -> TerminalPromptSelectionIntent? {
    let normalized = terminalTextEditingNormalizedModifiers(modifiers)
    guard !normalized.contains(.control) else { return nil }

    switch keyCode {
    case TerminalTextEditingKeyCode.leftArrow, TerminalTextEditingKeyCode.rightArrow:
        let direction: TerminalPromptSelectionDirection =
            keyCode == TerminalTextEditingKeyCode.leftArrow ? .backward : .forward
        switch normalized {
        case []: return .collapse(direction)
        case [.shift]: return .extend(direction, .character)
        case [.shift, .command]: return .extend(direction, .inputBoundary)
        default: return nil
        }
    case TerminalTextEditingKeyCode.backspace, TerminalTextEditingKeyCode.forwardDelete:
        return normalized.isSubset(of: [.shift]) ? .delete : nil
    default:
        guard producesText, !normalized.contains(.command) else { return nil }
        return .insertText
    }
}
