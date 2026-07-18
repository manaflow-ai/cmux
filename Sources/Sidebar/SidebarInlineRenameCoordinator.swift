import AppKit
import CmuxAppKitSupportUI

/// Complete state for one inline-rename lifecycle. The editing case owns the
/// draft and Escape state, so text input, key commands, focus loss, and cell
/// reuse cannot resolve different copies of the same session.
enum SidebarInlineRenamePhase: Equatable {
    struct Editing: Equatable {
        var draft: String
        var hasMovedCaretToStart: Bool
    }

    case idle
    case editing(Editing)
    case committed(String)
    case cancelled

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }
}

/// Signal-owned state machine shared by both AppKit sidebar rename bridges.
@MainActor
private final class SidebarInlineRenameSession {
    private let graph = SignalGraph()
    private let phase: Signal<SidebarInlineRenamePhase>

    init() {
        phase = graph.createSignal(.idle)
    }

    var currentPhase: SidebarInlineRenamePhase { phase.get() }

    func begin(draft: String) {
        phase.set(.editing(.init(draft: draft, hasMovedCaretToStart: false)))
    }

    func updateDraft(_ draft: String) {
        guard case var .editing(editing) = phase.get() else { return }
        editing.draft = draft
        phase.set(.editing(editing))
    }

    func moveCaretToStart() {
        guard case var .editing(editing) = phase.get() else { return }
        editing.hasMovedCaretToStart = true
        phase.set(.editing(editing))
    }

    func commit() {
        guard case let .editing(editing) = phase.get() else { return }
        phase.set(.committed(editing.draft))
    }

    func cancel() {
        guard case .editing = phase.get() else { return }
        phase.set(.cancelled)
    }

    func observe(_ body: @escaping @MainActor (SidebarInlineRenamePhase) -> Void) -> SignalEffect {
        graph.createEffect { [phase] _ in
            body(phase.get())
        }
    }
}

/// `NSTextFieldDelegate` that resolves field-editor commands into commit,
/// cancel, or caret-move actions and guarantees the rename resolves at most
/// once across Enter, Escape, and focus loss.
@MainActor
final class SidebarInlineRenameCoordinator: NSObject, NSTextFieldDelegate {
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    private let resolver = SidebarInlineRenameKeyResolver()
    private let session = SidebarInlineRenameSession()
    private var resolutionEffect: SignalEffect?

    /// Creates a coordinator bound to the commit and cancel closures.
    init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init()
        resolutionEffect = session.observe { [weak self] phase in
            guard let self else { return }
            switch phase {
            case let .committed(draft):
                self.onCommit(draft)
            case .cancelled:
                self.onCancel()
            case .idle, .editing:
                break
            }
        }
    }

    var phase: SidebarInlineRenamePhase { session.currentPhase }

    func begin(draft: String) {
        session.begin(draft: draft)
    }

    func updateDraft(_ draft: String) {
        session.updateDraft(draft)
    }

    func cancel() {
        session.cancel()
    }

    func observePhase(
        _ body: @escaping @MainActor (SidebarInlineRenamePhase) -> Void
    ) -> SignalEffect {
        session.observe(body)
    }

    /// Captures every AppKit edit into the signal before a later command or
    /// focus change resolves the session.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSControl else { return }
        let draft = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        session.updateDraft(draft)
    }

    /// Routes field-editor commands through the resolver.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }

        let hasMovedCaretToStart: Bool = {
            guard case let .editing(editing) = session.currentPhase else { return false }
            return editing.hasMovedCaretToStart
        }()
        switch resolver.action(for: commandSelector, hasMovedCaretToStart: hasMovedCaretToStart) {
        case .commit:
            session.commit()
            return true
        case .caretToStart:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            session.moveCaretToStart()
            return true
        case .cancel:
            session.cancel()
            return true
        case .passThrough:
            return false
        }
    }

    /// Treats focus loss as a commit. Terminal phases ignore later resolutions,
    /// so Return, Escape, and focus loss can only resolve once.
    func controlTextDidEndEditing(_ obj: Notification) {
        session.commit()
    }
}
