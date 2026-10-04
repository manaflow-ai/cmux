import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings

/// The `cmux.keybindings.*` ops of the Keyboard Shortcuts page (R59):
/// `list` (the binding table with conflicts, `KeybindingReports.list`),
/// `record.start` / `record.stop` with the `recorded` stream (the key
/// dispatcher hands the page's keys to a `KeyRecorder`), and the `changed`
/// stream. `set`, `remove` and `reset` answer `cmux.keybindings.unsupported`
/// until keybindings.json is written by its owner (cmux-config, slice 4).
@MainActor
final class KeybindingsPageProvider: PageProvider {
    private unowned let services: AppServices
    /// The page's window: only its key-downs are recorded.
    var pageWindow: () -> NSWindow? = { nil }
    private var recorder: KeyRecorder?
    private var recordedListeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    init(services: AppServices) {
        self.services = services
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.keybindings.list":
            return KeybindingReports.list(params.objectValue ?? [:], registry: services.registry)
        case "cmux.keybindings.record.start":
            startRecording()
            return .object([:])
        case "cmux.keybindings.record.stop":
            stopRecording()
            return .object([:])
        case "cmux.keybindings.set", "cmux.keybindings.remove", "cmux.keybindings.reset":
            throw PageError(code: "cmux.keybindings.unsupported", message: KeybindingStrings.editingUnsupported)
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
            return PageSubscription { [weak self] in MainActor.assumeIsolated { _ = self?.recordedListeners.removeValue(forKey: id) } }
        case "cmux.keybindings.changed":
            // Fires when keybindings.json loads (slice 4); nothing changes the table from here yet.
            return PageSubscription {}
        default:
            throw PageError.unknownOp(stream)
        }
    }

    private func startRecording() {
        recorder = KeyRecorder()
        services.keyRouter.keyRecorder = { [weak self] event, window in
            guard let self, let page = self.pageWindow(), window === page || window?.parent === page else { return false }
            self.record(event)
            return true
        }
    }

    private func stopRecording() {
        recorder = nil
        services.keyRouter.keyRecorder = nil
    }

    private func record(_ event: NSEvent) {
        guard var recorder,
              let recorded = recorder.record(KeyRecorder.stroke(for: event), isEscape: KeyRecorder.isEscape(event),
                                             isReturn: KeyRecorder.isReturn(event)) else { return }
        self.recorder = recorder
        if recorded.done || recorded.cancelled { stopRecording() }
        let event: JSONValue = [
            "key": .string(KeybindingReports.text(recorded.keys)),
            "display": .string(recorded.keys.map(\.displayString).joined(separator: " ")),
            "done": .bool(recorded.done), "cancelled": .bool(recorded.cancelled),
        ]
        for listener in recordedListeners.values { listener(event) }
    }
}
