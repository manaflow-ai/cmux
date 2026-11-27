import Foundation
import CmuxNextDictation
import CmuxNextSettings

public nonisolated enum AgentPaneVoiceCommand: Equatable, Sendable {
    case toggle, cancel, skip, restart
}

/// Platform adapter only: Rust owns utterance detection, interruption, filtering and speech order.
/// A native click starts a lease on this exact chat/connection. Every async callback carries that
/// lease, and cancellation tears down I/O synchronously before any daemon reply can return.
@MainActor
public final class AgentPaneVoiceRegistry {
    public init() {}

    public var environment: (@MainActor () -> AcpmuxEnvironment?)?
    private let relays = NSHashTable<AgentPaneVoiceRelay>.weakObjects()

    func register(_ relay: AgentPaneVoiceRelay) { relays.add(relay) }

    func stopForManualReadAloud(owner: AnyObject) {
        guard !(owner is AgentPaneVoiceRelay) else { return }
        for relay in relays.allObjects where relay.active { relay.cancel() }
    }

    public func keyChanged(account: String, removed: Bool) {
        for relay in relays.allObjects where relay.active && relay.keyAccount == account {
            if removed { relay.fail(AgentPaneDictation.failureMessage(.providerFailed(code: "key_missing", detail: ""))) }
            else { relay.restartRequired = true; relay.push() }
        }
    }
}

@MainActor
final class AgentPaneVoiceRelay {
    private let registry: AgentPaneVoiceRegistry
    weak var view: AgentPaneView?
    private(set) var epoch = 0
    private var scope: (session: String, connection: Int)?
    private var local: AcpmuxEnvironment?
    private var captured: [String: String] = [:]
    fileprivate var keyAccount: String?
    private var state: JSONValue = .null
    private var pending: [JSONValue] = []
    private var drain: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var microphone: DictationSession?
    private var captureID = ""
    private var captureText = ""
    private var unsent: [(id: String, text: String)] = []
    private var level: Float = 0
    private var wire = AgentPaneVoiceWire()
    private var wireFrames: [String] = []
    private var wireBytes = 0
    private var wireTask: Task<Void, Never>?
    fileprivate var restartRequired = false
    private var shownPhase = "idle"
    private var failureMessage: String?
    private lazy var fallbackReader = AgentPaneReadAloud(registry: registry)

    init(view: AgentPaneView, registry: AgentPaneVoiceRegistry) {
        self.view = view
        self.registry = registry
        registry.register(self)
    }
    private var reader: AgentPaneReadAloud { view?.model.readAloud ?? fallbackReader }
    private var generation: JSONValue { state["generation"] ?? .number(0) }
    fileprivate var active: Bool { scope != nil }

    var event: AgentPageEvent {
        var value: [String: JSONValue] = ["state": .string(shownPhase), "enabled": .bool(view?.model.composer.voiceButton == true),
            "level": .number(Double(level)), "restartRequired": .bool(restartRequired)]
        value["message"] = .string(failureMessage ?? message)
        return AgentPageEvent(kind: "voice", value: .object(value))
    }
    private var message: String {
        if restartRequired { return String(localized: "agentPane.voice.restartRequired", defaultValue: "Voice provider changed. Restart to use it.", bundle: .localizedModule) }
        switch shownPhase {
        case "connecting": return String(localized: "agentPane.voice.connecting", defaultValue: "Connecting", bundle: .localizedModule)
        case "listening", "interrupted", "finalizing": return String(localized: "agentPane.voice.listening", defaultValue: "Listening", bundle: .localizedModule)
        case "thinking": return String(localized: "agentPane.voice.thinking", defaultValue: "Agent is working", bundle: .localizedModule)
        case "speaking": return String(localized: "agentPane.voice.speaking", defaultValue: "Speaking", bundle: .localizedModule)
        case "error": return String(localized: "agentPane.voice.stopped", defaultValue: "Voice stopped. Try again.", bundle: .localizedModule)
        default: return ""
        }
    }
    func push() {
        let event = event
        view?.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.voice?.(\(event.value.compactText));"])
    }
    func handle(_ command: AgentPaneVoiceCommand) {
        switch command {
        case .cancel: cancel()
        case .toggle: if active { cancel() } else { start() }
        case .restart: cancel(); start()
        case .skip: enqueue("skip")
        }
    }
    func cancel() {
        epoch += 1
        scope = nil
        startTask?.cancel(); startTask = nil
        drain?.cancel(); drain = nil
        wireTask?.cancel(); wireTask = nil
        wireFrames.removeAll(); wireBytes = 0
        meterTask?.cancel(); meterTask = nil
        microphone?.onUpdate = nil
        microphone?.cancel(); microphone = nil
        DictationMicrophoneClaims.shared.release(self)
        reader.stop(owner: self)
        pending.removeAll(); unsent.removeAll(); captureText = ""
        state = .null; wire = AgentPaneVoiceWire()
        level = 0; shownPhase = "idle"; failureMessage = nil; restartRequired = false
        push()
    }
    private func start() {
        guard let view, view.model.composer.voiceButton,
              let session = view.model.sessionId, let connection = view.model.transport.connection,
              let environment = registry.environment?() else { return }
        epoch += 1
        let lease = epoch
        scope = (session, connection); local = environment
        shownPhase = "connecting"; push()
        // task-owner: this lease; cancel/navigation/close cancels it and rejects its late result.
        startTask = Task { [weak self] in
            do {
                let data = try await environment.harness(.voiceState)
                let reply = try JSONDecoder().decode(JSONValue.self, from: data)
                guard let self, self.valid(lease) else { return }
                guard let snapshot = reply["settings"]?.objectValue else { self.fail(); return }
                self.captured = snapshot.compactMapValues(\.stringValue)
                if self.captured["engine"] == "" { self.captured["engine"] = "onDevice" }
                self.keyAccount = reply["keyAccount"]?.stringValue
                guard self.captured.count == 3 else { self.fail(); return }
                let configured = reply["error"] == .null &&
                    (reply["key"]?.stringValue != "required" || reply["hasKey"]?.boolValue == true)
                guard configured else {
                    self.fail(AgentPaneDictation.failureMessage(.providerFailed(code: reply["error"]?["code"]?.stringValue ?? "key_missing", detail: "")))
                    return
                }
                if self.captured["engine"] != "onDevice" {
                    let checked = try await environment.harness(.voiceCheck, params: ["settings": self.captured])
                    guard self.valid(lease) else { return }
                    let result = try JSONDecoder().decode(JSONValue.self, from: checked)
                    if let error = result["error"], !error.isNull {
                        self.fail(AgentPaneDictation.failureMessage(.providerFailed(code: error["code"]?.stringValue ?? "provider_error", detail: "")))
                        return
                    }
                }
                self.enqueue("start", ["providerRevision": .number(Double(lease)), "configured": .bool(true)])
            } catch { guard let self, self.valid(lease) else { return }; self.fail() }
        }
    }
    func valid(_ lease: Int) -> Bool {
        guard epoch == lease, let scope, let view else { return false }
        return view.model.sessionId == scope.session && view.model.transport.connection == scope.connection
    }
    func settingsChanged(_ settings: AgentPaneComposerSetting) {
        // Availability follows the setting even before a lease starts and after cancellation.
        // The page otherwise has no Start control with which to create the first lease.
        guard active else { push(); return }
        if !settings.voiceButton { cancel(); return }
        if !captured.isEmpty && captured != ["engine": settings.dictationEngine.rawValue,
            "url": settings.dictationEngineURL, "model": settings.dictationEngineModel] {
            // Keep this session bound to its captured provider; changing it requires another click.
            restartRequired = true; push()
        }
    }
    fileprivate func fail(_ message: String? = nil) {
        // Snapshot before cancellation destroys capture state. A user cancel/navigation never
        // takes this path: recovery belongs only to this still-visible chat's failed I/O.
        let session = valid(epoch) ? scope?.session : nil
        let text = (unsent.map(\.text) + [captureText]).filter { !$0.isEmpty }.joined(separator: "\n")
        cancel()
        if let session {
            let updates = Self.recoveryUpdates(text: text, session: session)
            view?.deliver(updates.compactMap(AgentPageEvent.dictation),
                scripts: updates.compactMap(AgentPaneDictation.script))
        }
        shownPhase = "error"
        failureMessage = message ?? String(localized: "agentPane.voice.failed", defaultValue: "Voice stopped. Check your voice provider and try again.", bundle: .localizedModule)
        push()
    }
    /// Start supplies the existing composer anchor; failure keeps the words without triggering
    /// dictation's optional idle/auto-send path. Both bridges receive the identical ordered pair.
    static func recoveryUpdates(text: String, session: String) -> [DictationUpdate] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [DictationUpdate(phase: .starting, chat: session),
            DictationUpdate(phase: .failed(.providerFailed(code: "voice_relay", detail: "")), chat: session, text: text)]
    }
    private func enqueue(_ type: String, _ fields: [String: JSONValue] = [:]) {
        guard active else { return }
        var event = fields; event["type"] = .string(type)
        if event["generation"] == nil { event["generation"] = generation }
        // Meter work is lossy; transcript/text/effects stay ordered. A stalled local daemon cannot
        // accumulate unbounded events during a long live chat.
        if type == "audioActivity" || type == "tick" {
            pending.removeAll { $0["type"]?.stringValue == type }
        }
        guard pending.count < 256 else { fail(); return }
        pending.append(.object(event))
        guard drain == nil else { return }
        let lease = epoch
        drain = Task { [weak self] in await self?.reduce(lease) }
    }
    private func reduce(_ lease: Int) async {
        while valid(lease), !pending.isEmpty, let local {
            let event = pending.removeFirst()
            do {
                let reply = try await local.harness(.voiceRelay, params: ["state": state.voiceObject, "event": event.voiceObject])
                guard valid(lease) else { return }
                let result = try JSONDecoder().decode(JSONValue.self, from: reply)
                guard let next = result["state"], let effects = result["effects"]?.arrayValue else { fail(); return }
                state = next
                shownPhase = next["phase"]?.stringValue ?? "error"
                if shownPhase == "error" { fail(); return }
                if event["type"]?.stringValue == "transcript", let id = event["id"]?.stringValue,
                   !effects.contains(where: { $0["type"]?.stringValue == "sendPrompt" && $0["id"]?.stringValue == id }) {
                    unsent.removeAll { $0.id == id } // Rust rejected noise or a duplicate.
                }
                for effect in effects { apply(effect, lease: lease) }
                push()
            } catch { guard valid(lease) else { return }; fail(); return }
        }
        if valid(lease) { drain = nil }
    }
    private func apply(_ effect: JSONValue, lease: Int) {
        guard valid(lease) else { return }
        switch effect["type"]?.stringValue {
        case "startListening": listen(lease)
        case "stopListening":
            if shownPhase == "idle" { cancel() } else { microphone?.stop() }
        case "stopSpeaking": reader.stop(owner: self)
        case "sendPrompt":
            guard let id = effect["id"]?.stringValue, let text = effect["text"]?.stringValue,
                  let scope, let view else { return }
            let request = AgentPaneVoiceWire.prompt(session: scope.session, id: id, text: text)
            view.model.transport.submit(connection: scope.connection, frames: [request], valid: { [weak self] in
                self?.valid(lease) == true
            }) { [weak self] error in
                guard let self, self.valid(lease) else { return }
                if error == nil { self.unsent.removeAll { $0.id == id }; return }
                self.fail(String(localized: "agentPane.voice.sendFailed", defaultValue: "Voice could not send your message. Try again.", bundle: .localizedModule))
            }
        case "speak":
            guard let id = effect["id"]?.stringValue, let text = effect["text"]?.stringValue else { return }
            reader.speak(text, id: id, language: nil, owner: self) { [weak self] in
                guard let self, self.valid(lease) else { return }
                self.enqueue("speechFinished", ["id": .string(id)])
            }
        default: break
        }
    }
    private func listen(_ lease: Int) {
        guard let local, microphone == nil || microphone?.phase.isStartable == true else { return }
        let snapshot = captured
        let session = DictationSession(makeTranscriber: { meter in
            if snapshot["engine"] == "onDevice" { return OnDeviceDictationTranscriber(levelMeter: meter, voiceProcessing: true) }
            return RecordedDictationTranscriber(levelMeter: meter, transcribe: { audio, locale in
                try await DictationProviderEngine.transcribe(audio, locale: locale, environment: local, settings: snapshot)
            }, capture: MicrophoneDictationCapture(voiceProcessing: true))
        })
        microphone = session; captureID = UUID().uuidString; captureText = ""
        let id = captureID
        var announced = false
        session.onUpdate = { [weak self] update in
            guard let self, self.valid(lease), self.captureID == id, !update.cancelled else { return }
            self.level = update.level
            self.captureText = update.text
            switch update.phase {
            case .listening:
                if !announced { announced = true; self.enqueue("listening") }
                // Meter task feeds the reducer at a bounded rate.
            case .idle:
                self.meterTask?.cancel(); self.meterTask = nil
                guard self.unsent.count < 256 else { self.fail(); return }
                self.unsent.append((id, update.text)); self.captureText = ""
                self.enqueue("transcript", ["id": .string(id), "text": .string(update.text)])
            case .failed(let error): self.fail(AgentPaneDictation.failureMessage(error))
            case .denied(let permission): self.fail(AgentPaneDictation.deniedMessage(permission))
            default: break
            }
        }
        DictationMicrophoneClaims.shared.claim(self) { [weak self] in self?.cancel() }
        session.start()
        meterTask?.cancel()
        // task-owner: microphone capture; no timer survives cancellation or finalization.
        meterTask = Task { [weak self] in
            while !Task.isCancelled { // wakeup-allow: bounded microphone meter cadence; cancellation tears it down.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return } // wakeup-allow: bounded cadence, never external polling.
                guard let self, self.valid(lease), self.captureID == id else { return }
                guard self.microphone?.phase == .listening else { continue }
                let time = JSONValue.number((ProcessInfo.processInfo.systemUptime * 1000).rounded(.down))
                self.enqueue("audioActivity", ["level": .number(Double(self.level)), "atMs": time])
                self.enqueue("tick", ["atMs": time])
            }
        }
    }
    func receive(_ event: AgentPaneTransportEvent) {
        guard let scope else { return }
        guard event.connection == scope.connection, event.closed == nil, valid(epoch) else { cancel(); return }
        wireBytes += event.frames.reduce(0) { $0 + $1.utf8.count }
        guard wireBytes <= 16 * 1024 * 1024, wireFrames.count + event.frames.count <= 512 else { fail(); return }
        wireFrames += event.frames
        guard wireTask == nil else { return }
        let lease = epoch
        // task-owner: this voice lease; ordered parsing off-main, discarded on navigation/cancel.
        wireTask = Task { [weak self] in await self?.readFrames(lease, session: scope.session) }
    }
    private func readFrames(_ lease: Int, session: String) async {
        while valid(lease), !wireFrames.isEmpty {
            let frames = Array(wireFrames.prefix(64))
            wireFrames.removeFirst(frames.count)
            wireBytes -= frames.reduce(0) { $0 + $1.utf8.count }
            let (next, texts) = await AgentPaneVoiceWire.receive(frames, session: session, state: wire)
            guard valid(lease) else { return }
            wire = next
            for text in texts {
                enqueue("agentText", ["id": .string(text.id), "text": .string(text.text), "done": .bool(text.done)])
            }
        }
        if valid(lease) { wireTask = nil }
    }
}

private extension JSONValue {
    /// Foundation JSON objects, recursively Sendable, for the local unix-socket client.
    var voiceObject: any Sendable {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.voiceObject)
        case .object(let values): values.mapValues(\.voiceObject)
        }
    }
}

/// Settings signals a successful key mutation without transferring a key to a chat or page.
