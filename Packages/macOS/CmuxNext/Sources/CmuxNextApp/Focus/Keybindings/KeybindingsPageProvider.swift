import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings
import CmuxNextDesign
import UniformTypeIdentifiers

/// The `cmux.keybindings.*` ops of the Keyboard Shortcuts page (R59):
/// `list` (the binding table with conflicts, `KeybindingReports.list`),
/// `record.start` / `record.stop` with the `recorded` stream (the key
/// dispatcher hands the page's keys to a `KeyRecorder`), and the `changed`
/// stream. `set`, `remove` and `reset` write cmux.json, or keybindings.json
/// through the home daemon (`KeybindingPageWrites`).
@MainActor
final class KeybindingsPageProvider: PageProvider {
    private unowned let services: AppServices
    /// The page's window: only its key-downs are recorded.
    var pageWindow: () -> NSWindow? = { nil }
    private var recorder: KeyRecorder?
    /// While recording: the modifier changes and key-ups of the page's window, so the page shows
    /// the modifiers held before a key makes the stroke, and knows when every key of one is up.
    private var flagsMonitor: Any?
    /// A stroke was recorded and some of its keys are still down.
    private var awaitingRelease = false
    /// The held modifiers last sent: a keyboard can repeat a modifier change with nothing new.
    private var sentHeld = ""
    private var recordedListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var changedListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var fileListener: UUID?

    init(services: AppServices) {
        self.services = services
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.keybindings.list":
            return KeybindingReports.pageList(params.objectValue ?? [:], registry: services.registry,
                                             heldElsewhere: services.globalHotKeys.conflicts)
        case "cmux.keybindings.conflicts":
            // The entries the keys would take, and the app's refusal of them (`refusal`), before a save.
            let fields = params.objectValue ?? [:]
            let writes = services.settings.map {
                KeybindingPageWrites(registry: services.registry, settings: $0, file: services.keybindingsFile)
            }
            let when = writes.map { $0.savedWhen(fields) }
                ?? fields["when"]?.stringValue.flatMap { try? WhenClause.parse($0) }
            let asDefault = writes?.restoresDefault(fields) ?? false
            let sameScope = writes?.sameScopeOwners(fields) ?? []
            guard case .object(var reply) = KeybindingReports.conflicts(fields, when: when, asDefault: asDefault,
                                                                        sameScope: sameScope, registry: services.registry)
            else { return [:] }
            if let refusal = writes?.refusal(fields) {
                reply["refusal"] = .string(refusal.message)
                // The action that holds the keys (a system action that always runs, a numbered family).
                if let owner = refusal.owner {
                    reply["owner"] = .string(services.registry.title(for: owner) ?? owner.rawValue)
                }
            }
            return .object(reply)
        case "cmux.keybindings.record.start":
            // A row's recorder and the search's start a new shortcut after each release.
            startRecording()
            return .object([:])
        case "cmux.keybindings.record.stop":
            stopRecording()
            return .object([:])
        case "cmux.keybindings.keymap.export":
            return try await keymapFile(export: true)
        case "cmux.keybindings.keymap.import":
            return try await keymapFile(export: false)
        case "cmux.keybindings.set", "cmux.keybindings.remove", "cmux.keybindings.reset":
            // The page hears its own edit as the socket's: `cmux.keybindings.changed`.
            let edit: KeybindingEdit = op == "cmux.keybindings.set" ? .set : op == "cmux.keybindings.remove" ? .remove : .reset
            try await edit.run(params.objectValue ?? [:], services: services)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        switch stream {
        case "cmux.keybindings.recorded":
            let id = UUID()
            recordedListeners[id] = onEvent
            // The page went away: a recording it started never keeps the window's keys.
            return PageSubscription { [weak self] in
                guard let self else { return }
                recordedListeners[id] = nil
                if recordedListeners.isEmpty { stopRecording() }  // only a capture this page owns
            }
        case "cmux.keybindings.changed":
            // Fires after a keymap import, an edit (the page's or the socket's) and whenever keybindings.json loads.
            let id = UUID()
            changedListeners[id] = onEvent
            if fileListener == nil {
                fileListener = services.keybindingsFile.onChange { [weak self] in
                    for listener in self?.changedListeners.values.map({ $0 }) ?? [] { listener([:]) }
                }
            }
            return PageSubscription { [weak self] in
                guard let self else { return }
                changedListeners[id] = nil
                if changedListeners.isEmpty, let fileListener {
                    services.keybindingsFile.removeListener(fileListener)
                    self.fileListener = nil
                }
            }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// Export Keymap… / Import Keymap… (parity with the Swift Settings
    /// Keyboard section): a save or open panel on the page's window, then
    /// the settings owner writes or imports the `shortcuts` object. Returns
    /// `{path}`, or `{cancelled: true}` when the person closed the panel.
    private func keymapFile(export: Bool) async throws -> JSONValue {
        guard let settings = services.settings else {
            throw PageError(code: "cmux.keybindings.keymap_failed", message: KeybindingStrings.editingUnsupported)
        }
        let url: URL? = await withCheckedContinuation { continuation in
            let panel: NSSavePanel
            if export {
                panel = NSSavePanel()
                panel.nameFieldStringValue = "cmux-next-keymap.json"
            } else {
                let open = NSOpenPanel()
                open.allowsMultipleSelection = false
                panel = open
            }
            panel.allowedContentTypes = [.json]
            panel.beginForCmux(in: pageWindow()) { continuation.resume(returning: $0) }
        }
        guard let url else { return ["cancelled": true] }
        do {
            if export {
                try await settings.exportShortcutKeymap(to: url)
            } else {
                try await settings.importShortcutKeymap(from: url)
                for listener in changedListeners.values { listener([:]) }
            }
        } catch {
            throw PageError(code: "cmux.keybindings.keymap_failed", message: String(describing: error))
        }
        return ["path": .string(url.path)]
    }

    private func startRecording() {
        // One slot for every window's page: another page recording loses it, and says so.
        if let holder = services.keyRouter.keyRecorderOwner as? KeybindingsPageProvider, holder !== self {
            holder.loseCapture()
        }
        recorder = KeyRecorder()
        awaitingRelease = false
        sentHeld = ""
        services.keyRouter.keyRecorderOwner = self
        services.keyRouter.keyRecorder = { [weak self] event, window in
            guard let self, let page = self.pageWindow(), window === page || window?.parent === page else { return false }
            self.record(event)
            return true
        }
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp]) { [weak self] event in
                self?.hold(event)
                return event
            }
        }
    }

    /// Ends this provider's capture. The key router's slot is one for every window's page: only
    /// the provider that holds it clears it, and one that is not recording does nothing.
    private func stopRecording() {
        guard recorder != nil else { return }
        recorder = nil
        awaitingRelease = false
        if services.keyRouter.keyRecorderOwner === self {
            services.keyRouter.keyRecorder = nil
            services.keyRouter.keyRecorderOwner = nil
        }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    /// Another window's page took the capture slot: this page's recording ends as cancelled.
    private func loseCapture() {
        guard recorder != nil else { return }
        stopRecording()
        send([], done: false, cancelled: true, held: "")
    }

    private func record(_ event: NSEvent) {
        // A held key's repeats are not more strokes (holding ⌥⌘0 a moment recorded ⌥⌘0 ⌥⌘0).
        guard !event.isARepeat else { return }
        guard var recorder,
              let recorded = recorder.record(KeyRecorder.stroke(for: event), isEscape: KeyRecorder.isEscape(event),
                                             isReturn: KeyRecorder.isReturn(event)) else { return }
        self.recorder = recorder
        if recorded.done || recorded.cancelled { stopRecording() }
        awaitingRelease = !recorded.keys.isEmpty && !recorded.done && !recorded.cancelled
        send(recorded.keys, done: recorded.done, cancelled: recorded.cancelled, held: "")
    }

    /// A modifier or key went up or down in the page's window: the strokes so far and the
    /// modifiers held now; `released` once every key of the last stroke is up.
    private func hold(_ event: NSEvent) {
        // The key window, as the key router reads it for the strokes (`CmuxApplication.dispatch`):
        // a modifier change or key-up can name no window, or another one, of its own.
        let window = NSApp.keyWindow ?? event.window
        guard let recorder, !recorder.isFinished, let page = pageWindow(),
              window === page || window?.parent === page else { return }
        let held = KeyRecorder.heldGlyphs(event.modifierFlags)
        if awaitingRelease, held.isEmpty {
            awaitingRelease = false
            send(recorder.keys, done: false, cancelled: false, held: "", released: true)
            // Every key up ends the shortcut (the page saves it, or searches by it): the next key
            // starts a new one, which replaces it. A chord is typed with a modifier held between
            // its strokes.
            self.recorder = KeyRecorder()
            return
        }
        if event.type == .flagsChanged, held != sentHeld { send(recorder.keys, done: false, cancelled: false, held: held) }
    }

    /// One `recorded` event: the strokes so far (`key`, `display`), how the recording ended,
    /// `held`, the glyphs of the modifiers held before the next key ("" on a stroke), and
    /// `released` when every key of the last stroke is up (the page saves the keys then; the next
    /// stroke starts a new shortcut).
    private func send(_ keys: [Shortcut], done: Bool, cancelled: Bool, held: String, released: Bool = false) {
        sentHeld = held
        let event: JSONValue = [
            "key": .string(KeybindingReports.text(keys)),
            "display": .string(keys.map(\.displayString).joined(separator: " ")),
            "done": .bool(done), "cancelled": .bool(cancelled), "held": .string(held), "released": .bool(released),
        ]
        for listener in recordedListeners.values { listener(event) }
    }
}
