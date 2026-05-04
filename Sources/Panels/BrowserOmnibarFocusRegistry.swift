import AppKit
import Foundation

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

func browserOmnibarPanelId(for responder: NSResponder?) -> UUID? {
    browserOmnibarField(for: responder)?.panelId
}

@discardableResult
func browserPrepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
    guard let field = browserOmnibarField(for: responder),
          field.panelId == panelId else {
        return false
    }
    field.suppressNextFocusReacquireOnEndEditing = true
    return true
}

private func browserOmnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
    guard let responder else { return nil }

    if let field = responder as? OmnibarNativeTextField {
        return field
    }

    if let editor = responder as? NSTextView,
       editor.isFieldEditor,
       let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
       field.currentEditor() === editor {
        return field
    }

    return nil
}

@MainActor
final class BrowserOmnibarFocusRegistry {
    static let shared = BrowserOmnibarFocusRegistry()

    private final class WeakField {
        weak var field: OmnibarNativeTextField?

        init(_ field: OmnibarNativeTextField) {
            self.field = field
        }
    }

    private var fieldsByPanelId: [UUID: WeakField] = [:]
    private var pendingFocusRequestsByPanelId: [UUID: Bool] = [:]
    private var userEditedFocusRequestByPanelId: [UUID: UUID] = [:]

    private init() {}

    func register(
        _ field: OmnibarNativeTextField,
        panelId: UUID?,
        applyPendingFocus: Bool = true
    ) {
        guard let panelId else { return }
        fieldsByPanelId[panelId] = WeakField(field)
        guard applyPendingFocus else { return }
        _ = applyPendingFocusIfPossible(panelId: panelId)
    }

    func syncAttachedRegistration(
        _ field: OmnibarNativeTextField,
        panelId: UUID?,
        applyPendingFocus: Bool = true
    ) {
        if field.panelId != panelId {
            unregister(field)
        }
        field.panelId = panelId
        guard field.window != nil else {
            unregister(field)
            return
        }
        register(field, panelId: panelId, applyPendingFocus: applyPendingFocus)
    }

    func unregister(_ field: OmnibarNativeTextField) {
        guard let panelId = field.panelId,
              fieldsByPanelId[panelId]?.field === field else {
            return
        }
        fieldsByPanelId[panelId] = nil
        userEditedFocusRequestByPanelId[panelId] = nil
    }

    @discardableResult
    func requestFocus(panelId: UUID, selectAll: Bool) -> Bool {
        _ = recordPendingFocus(panelId: panelId, selectAll: selectAll)
        return applyPendingFocusIfPossible(panelId: panelId)
    }

    func requestFocusAfterViewUpdate(
        panelId: UUID,
        selectAll: Bool,
        shouldApply: @escaping () -> Bool,
        onComplete: @escaping () -> Void
    ) {
        // SwiftUI can call updateNSView while AppKit text input is ending editing.
        // Keep the Cmd+L shortcut path synchronous, but replay this fallback next turn.
        _ = recordPendingFocus(panelId: panelId, selectAll: selectAll)
        DispatchQueue.main.async { [weak self] in
            defer { onComplete() }
            guard let self else { return }
            guard shouldApply() else {
                self.pendingFocusRequestsByPanelId[panelId] = nil
                return
            }
            _ = self.applyPendingFocusIfPossible(panelId: panelId)
        }
    }

    func markUserEditedPendingFocus(panelId: UUID, requestId: UUID) {
        userEditedFocusRequestByPanelId[panelId] = requestId
    }

    func consumeUserEditedPendingFocus(panelId: UUID, requestId: UUID) -> Bool {
        guard userEditedFocusRequestByPanelId[panelId] == requestId else {
            return false
        }
        userEditedFocusRequestByPanelId[panelId] = nil
        pendingFocusRequestsByPanelId[panelId] = nil
        return true
    }

    @discardableResult
    private func recordPendingFocus(panelId: UUID, selectAll: Bool) -> Bool {
        let effectiveSelectAll = (pendingFocusRequestsByPanelId[panelId] ?? false) || selectAll
        pendingFocusRequestsByPanelId[panelId] = effectiveSelectAll
        return effectiveSelectAll
    }

    @discardableResult
    private func applyPendingFocusIfPossible(panelId: UUID) -> Bool {
        guard let selectAll = pendingFocusRequestsByPanelId[panelId] else {
            return false
        }
        let didFocus = focusRegisteredField(panelId: panelId, selectAll: selectAll)
        if didFocus {
            pendingFocusRequestsByPanelId[panelId] = nil
        }
        return didFocus
    }

    @discardableResult
    private func focusRegisteredField(panelId: UUID, selectAll: Bool) -> Bool {
        guard let field = fieldsByPanelId[panelId]?.field else {
            fieldsByPanelId[panelId] = nil
            return false
        }
        guard let window = field.window,
              !field.isHiddenOrHasHiddenAncestor,
              field.isEnabled,
              field.isEditable else {
            return false
        }

        let firstResponder = window.firstResponder
        let alreadyFocused =
            firstResponder === field ||
            field.currentEditor() != nil ||
            ((firstResponder as? NSTextView)?.delegate as? NSTextField) === field

        if !alreadyFocused {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.omnibar.registry.apply panel=\(panelId.uuidString.prefix(5)) " +
                "win=\(window.windowNumber) selectAll=\(selectAll ? 1 : 0)"
            )
#endif
            field.suppressNextFocusReacquireOnEndEditing = false
            guard window.makeFirstResponder(field) else {
                return false
            }
        }

        if selectAll {
            field.selectAllTextForProgrammaticFocus()
        }
#if DEBUG
        BrowserOmnibarFocusLatencyTracker.shared.markNativeFocus(
            panelId: panelId,
            alreadyFocused: alreadyFocused,
            selectAll: selectAll,
            window: window
        )
#endif
        return true
    }
}

#if DEBUG
@MainActor
final class BrowserOmnibarFocusLatencyTracker {
    static let shared = BrowserOmnibarFocusLatencyTracker()

    private struct Sample {
        let panelId: UUID
        let requestId: UUID
        let workspaceId: UUID?
        let startedAt: TimeInterval
        let totalPanelCount: Int
        let browserPanelCount: Int
        var didLogRequestApply = false
        var didLogNativeFocus = false
        var didLogFirstAppKey = false
        var didLogFirstFieldKey = false
    }

    private var samplesByPanelId: [UUID: Sample] = [:]
    private var latestPanelId: UUID?
    private let sampleLifetime: TimeInterval = 8

    private init() {}

    func begin(
        panelId: UUID,
        requestId: UUID,
        workspaceId: UUID?,
        totalPanelCount: Int,
        browserPanelCount: Int
    ) {
        pruneExpiredSamples()
        let sample = Sample(
            panelId: panelId,
            requestId: requestId,
            workspaceId: workspaceId,
            startedAt: ProcessInfo.processInfo.systemUptime,
            totalPanelCount: totalPanelCount,
            browserPanelCount: browserPanelCount
        )
        samplesByPanelId[panelId] = sample
        latestPanelId = panelId
        cmuxDebugLog(
            "browser.focus.addressBar.latency.start " +
            "panel=\(short(panelId)) request=\(short(requestId)) workspace=\(short(workspaceId)) " +
            "panels=\(totalPanelCount) browsers=\(browserPanelCount)"
        )
    }

    func markRequestApply(panelId: UUID, requestId: UUID) {
        guard var sample = sample(for: panelId), !sample.didLogRequestApply else { return }
        guard sample.requestId == requestId else { return }
        sample.didLogRequestApply = true
        samplesByPanelId[panelId] = sample
        log(
            "requestApply",
            sample: sample,
            extra: "request=\(short(requestId))"
        )
    }

    func markNativeFocus(panelId: UUID, alreadyFocused: Bool, selectAll: Bool, window: NSWindow?) {
        guard var sample = sample(for: panelId), !sample.didLogNativeFocus else { return }
        sample.didLogNativeFocus = true
        samplesByPanelId[panelId] = sample
        let firstResponder = responderDescription(window?.firstResponder)
        log(
            "nativeFocus",
            sample: sample,
            extra: "alreadyFocused=\(alreadyFocused ? 1 : 0) selectAll=\(selectAll ? 1 : 0) " +
                "win=\(window?.windowNumber ?? -1) fr=\(firstResponder)"
        )
    }

    func markAppKey(event: NSEvent, firstResponder: NSResponder?, addressBarPanelId: UUID?) {
        guard isTypingKey(event) else { return }
        guard let panelId = addressBarPanelId.flatMap({ samplesByPanelId[$0] == nil ? nil : $0 }) ?? latestPanelId,
              var sample = sample(for: panelId),
              !sample.didLogFirstAppKey else {
            return
        }
        sample.didLogFirstAppKey = true
        samplesByPanelId[panelId] = sample
        log(
            "firstAppKey",
            sample: sample,
            event: event,
            extra: "fr=\(responderDescription(firstResponder)) nativeFocusLogged=\(sample.didLogNativeFocus ? 1 : 0)"
        )
    }

    func markFieldKeyDown(panelId: UUID, event: NSEvent, hasEditor: Bool) {
        guard isTypingKey(event) else { return }
        guard var sample = sample(for: panelId), !sample.didLogFirstFieldKey else { return }
        sample.didLogFirstFieldKey = true
        samplesByPanelId[panelId] = sample
        log(
            "firstFieldKey",
            sample: sample,
            event: event,
            extra: "hasEditor=\(hasEditor ? 1 : 0) nativeFocusLogged=\(sample.didLogNativeFocus ? 1 : 0)"
        )
    }

    private func sample(for panelId: UUID) -> Sample? {
        pruneExpiredSamples()
        return samplesByPanelId[panelId]
    }

    private func pruneExpiredSamples() {
        let now = ProcessInfo.processInfo.systemUptime
        samplesByPanelId = samplesByPanelId.filter { _, sample in
            now - sample.startedAt <= sampleLifetime
        }
        if let latestPanelId, samplesByPanelId[latestPanelId] == nil {
            self.latestPanelId = samplesByPanelId.max { left, right in
                left.value.startedAt < right.value.startedAt
            }?.key
        }
    }

    private func log(_ event: String, sample: Sample, event keyEvent: NSEvent? = nil, extra: String = "") {
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - sample.startedAt) * 1000.0
        var line =
            "browser.focus.addressBar.latency.\(event) " +
            "panel=\(short(sample.panelId)) request=\(short(sample.requestId)) workspace=\(short(sample.workspaceId)) " +
            "elapsedMs=\(format(elapsedMs)) panels=\(sample.totalPanelCount) browsers=\(sample.browserPanelCount)"
        if let keyEvent {
            line += " key=\(keyDescription(keyEvent)) eventDelayMs=\(format(eventDelayMs(keyEvent)))"
        }
        if !extra.isEmpty {
            line += " \(extra)"
        }
        cmuxDebugLog(line)
    }

    private func isTypingKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.isDisjoint(with: blockedModifiers) else { return false }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        return characters != "\u{1B}"
    }

    private func keyDescription(_ event: NSEvent) -> String {
        let characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let category: String
        if characters == "\r" {
            category = "return"
        } else if characters == "\u{7F}" {
            category = "delete"
        } else if characters == "\t" {
            category = "tab"
        } else if characters == "\u{1B}" {
            category = "escape"
        } else if characters.isEmpty {
            category = "none"
        } else if characters.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            category = "letter"
        } else if characters.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            category = "digit"
        } else if characters.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            category = "whitespace_control"
        } else {
            category = "symbol"
        }
        return "keyCode:\(event.keyCode) category:\(category)"
    }

    private func eventDelayMs(_ event: NSEvent) -> Double {
        guard event.timestamp > 0 else { return 0 }
        return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
    }

    private func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        if let textView = responder as? NSTextView,
           let delegate = textView.delegate {
            return "fieldEditor(delegate=\(String(describing: type(of: delegate))))"
        }
        return String(describing: type(of: responder))
    }

    private func short(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
#endif
