public import AppKit

private final class WeakOmnibarNativeTextField {
    weak var field: OmnibarNativeTextField?

    init(_ field: OmnibarNativeTextField) {
        self.field = field
    }
}

/// Live-field lookup cache mapping a browser panel id to its currently attached
/// omnibar native text field(s).
///
/// Ownership invariant: `OmnibarNativeTextField.panelId` is the single source of
/// truth for field-to-panel ownership, and a live omnibar field owns its current
/// field editor. AppKit's field-editor responder chain is the normal lookup
/// path, but it can keep a stale `nextResponder` during browser focus/layout
/// transitions. This weak registry is only a live-field lookup cache for those
/// stale-responder windows; it does not create ownership.
///
/// This used to be a process-wide `static let shared` singleton. It is now a
/// plain instance constructed by the owning browser-panel view and injected into
/// the omnibar text-field representable and the interaction representable, so all
/// surfaces that look up a panel's field share the same instance without a
/// global.
@MainActor
public final class BrowserOmnibarNativeFieldRegistry {
    private var fields: [UUID: [WeakOmnibarNativeTextField]] = [:]

    public init() {}

    public func register(_ field: OmnibarNativeTextField, panelId: UUID) {
        var entries = fields[panelId] ?? []
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        entries.append(WeakOmnibarNativeTextField(field))
        fields[panelId] = entries
    }

    public func unregister(_ field: OmnibarNativeTextField, panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { entry in
            guard let existing = entry.field else { return true }
            return existing === field
        }
        if entries.isEmpty {
            fields.removeValue(forKey: panelId)
        } else {
            fields[panelId] = entries
        }
    }

    public func field(for panelId: UUID?, in window: NSWindow? = nil) -> OmnibarNativeTextField? {
        guard let panelId else { return nil }
        pruneDeadEntries(for: panelId)
        guard let entries = fields[panelId] else { return nil }
        let liveFields = entries.reversed().compactMap(\.field)
        if let window {
            return liveFields.first(where: { $0.window === window })
        }
        return liveFields.first(where: { $0.window != nil }) ?? liveFields.first
    }

    public func fieldOwningEditor(_ editor: NSTextView, in window: NSWindow? = nil) -> OmnibarNativeTextField? {
        for panelId in Array(fields.keys) {
            pruneDeadEntries(for: panelId)
        }

        let liveFields = fields.values.flatMap { entries in
            entries.reversed().compactMap(\.field)
        }
        if let window,
           let windowField = liveFields.first(where: { $0.window === window && $0.currentEditor() === editor }) {
            return windowField
        }
        if let registeredField = liveFields.first(where: { $0.currentEditor() === editor }) {
            return registeredField
        }

        guard let root = window?.contentView?.superview ?? window?.contentView else {
            return nil
        }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let field = view as? OmnibarNativeTextField,
               field.currentEditor() === editor {
                return field
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func pruneDeadEntries(for panelId: UUID) {
        guard var entries = fields[panelId] else { return }
        entries.removeAll { $0.field == nil }
        if entries.isEmpty {
            fields.removeValue(forKey: panelId)
        } else {
            fields[panelId] = entries
        }
    }

    // MARK: - Responder-chain omnibar lookup
    //
    // These resolve the live omnibar field for a panel or responder, using the
    // registry cache first and falling back to a responder/view-tree walk for the
    // SwiftUI/AppKit reconnect windows where registration has not yet observed a
    // freshly attached native field.

    public func panelId(for responder: NSResponder?) -> UUID? {
        field(forResponder: responder)?.panelId
    }

    public func field(forPanelId panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
        if let registeredField = field(for: panelId, in: window) {
            return registeredField
        }
        guard let panelId, let root = window?.contentView?.superview ?? window?.contentView else {
            return nil
        }

        // Fallback for SwiftUI/AppKit reconnect windows where the live native field
        // has been attached but registration has not yet observed it.
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let field = view as? OmnibarNativeTextField, field.panelId == panelId {
                return field
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    @discardableResult
    public func prepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
        guard let field = field(forResponder: responder),
              field.panelId == panelId else {
            return false
        }
        field.suppressNextFocusReacquireOnEndEditing = true
        return true
    }

    private func field(forResponder responder: NSResponder?) -> OmnibarNativeTextField? {
        guard let responder else { return nil }

        if let field = responder as? OmnibarNativeTextField {
            return field
        }

        if let editor = responder as? NSTextView, editor.isFieldEditor {
            if let field = fieldOwningEditor(editor, in: editor.window) {
                return field
            }

            // TODO(refactor): cmuxFieldEditorOwnerView still lives in the app
            // target (Sources/App/ShortcutRoutingSupport.swift). The orchestrator
            // reconciles this dangling reference after all omnibar moves land.
            if let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
               field.currentEditor() === editor {
                return field
            }

        }

        return nil
    }
}
