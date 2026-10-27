package import AppKit

/// One terminal's TextBox: its model and view, installed under the terminal
/// (``TerminalHostView/bottomAccessory``) the first time it shows. A submit sends the draft
/// through its sink (a paste, then Return); Escape gives the keyboard back to the terminal.
/// Shift-Tab and the buttons run the registry's TextBox actions, the path every entrypoint takes.
package final class TextBoxController {
    package let model = TextBoxModel()
    private weak var session: TerminalSession?
    private let sink: any TextBoxSink
    private var installed: TextBoxView?

    /// - Parameters:
    ///   - session: The terminal the box sits under.
    ///   - sink: Where a submit goes; nil sends it into `session`'s input.
    ///   - perform: Runs the registry action of a ``TextBoxCommand`` (the App maps it to its `ActionID`).
    package init(session: TerminalSession, sink: (any TextBoxSink)? = nil, perform: @escaping @MainActor (TextBoxCommand) -> Void) {
        self.session = session
        self.sink = sink ?? TerminalSessionTextBoxSink(session: session)
        self.perform = perform
    }

    private let perform: @MainActor (TextBoxCommand) -> Void

    /// The strip under the terminal, made the first time it is asked for.
    package var view: TextBoxView {
        if let installed { return installed }
        let view = TextBoxView(model: model)
        view.perform = perform
        view.textView.onSubmit = { [weak self] in _ = self?.submit() }
        view.textView.onEscape = { [weak self] in self?.focusTerminal() }
        view.textView.onCycle = { [weak self] in self?.perform(.cycleSubmitAction) }
        installed = view
        session?.view.bottomAccessory = view
        return view
    }

    package var textView: TextBoxTextView { view.textView }

    /// The box's editor has the keyboard.
    package var hasKeyboard: Bool {
        guard let installed, let window = installed.window else { return false }
        return window.firstResponder === installed.textView
    }

    /// Shows the box; with `focus` its editor takes the keyboard.
    package func show(focus: Bool) {
        let view = self.view
        model.isVisible = true
        view.isHidden = false
        session?.view.needsLayout = true
        session?.view.layoutSubtreeIfNeeded()
        if focus { view.window?.makeFirstResponder(view.textView) }
    }

    /// Hides the box (the draft stays); the terminal takes the keyboard back when the box had it.
    package func hide() {
        let hadKeyboard = hasKeyboard
        model.isVisible = false
        installed?.isHidden = true
        session?.view.needsLayout = true
        if hadKeyboard { session?.focus() }
    }

    /// Shows a hidden box (taking the keyboard with `focus`), hides a shown one.
    package func toggle(focus: Bool) {
        if model.isVisible { hide() } else { show(focus: focus) }
    }

    /// The keyboard to the terminal.
    package func focusTerminal() { session?.focus() }

    /// Sends the draft through the submit action: a paste of its input, then Return. False for a blank draft.
    @discardableResult
    package func submit() -> Bool {
        installed?.commitText()
        guard let input = model.takeInput() else { return false }
        if installed?.textView.string.isEmpty == false { installed?.textView.replaceText("") }
        sink.paste(input)
        sink.pressReturn()
        return true
    }

    /// Adds `paths` to the draft, shell-quoted.
    package func insert(paths: [String]) {
        installed?.commitText()
        model.insert(paths: paths)
        if let installed, installed.textView.string != model.text {
            installed.textView.replaceText(model.text)
            installed.textView.setSelectedRange(NSRange(location: (model.text as NSString).length, length: 0))
        }
    }
}
