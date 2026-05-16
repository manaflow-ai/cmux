import Foundation
import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class VoiceInputController {
    let state = VoiceInputState()
    private let transport = VoiceRealtimeTransport()
    private let executor: VoiceToolExecutor
    private var audioEngine: AVAudioEngine?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )!

    private var hudPanel: NSPanel?

    private let model: String
    private let instructions = """
        You are a voice controller for cmux, a macOS terminal app. Use only the registered tools \
        to act on the app. Call get_app_state first when you need to know what workspaces or tabs \
        are open. When the user says 'type X', use type_text. When they say 'run X' or 'execute X', \
        use execute_command. Keep any spoken reply to one short sentence. Do not invent capabilities.
        """

    init(tabManager: TabManager, model: String = "gpt-4o-realtime-preview") {
        self.executor = VoiceToolExecutor()
        self.model = model
        transport.onStateChange = { [weak self] state in
            self?.handleTransportStateChange(state)
        }
        transport.onSessionCreated = { [weak self] in
            guard let self else { return }
            #if DEBUG
            cmuxDebugLog("voice.session.created — sending session.update")
            #endif
            transport.send(.sessionUpdate(
                model: model,
                instructions: instructions,
                tools: VoiceToolDefinitions.all
            ))
        }
        transport.onServerError = { [weak self] message in
            guard let self else { return }
            #if DEBUG
            cmuxDebugLog("voice.server.error \(message)")
            #endif
            stopAudioCapture()
            state.isActive = false
            state.activity = .error(message)
        }
        transport.onToolCall = { [weak self] call in
            self?.handleToolCall(call)
        }
        transport.onTranscript = { [weak self] text in
            guard !text.isEmpty else { return }
            #if DEBUG
            cmuxDebugLog("voice.transcript \(text.prefix(80))")
            #endif
            self?.state.transcript = text
        }
        transport.onTextDelta = { [weak self] delta in
            guard let self else { return }
            state.aiReply += delta
            if state.activity == .listening || state.activity == .executing {
                state.activity = .processing
            }
        }
        transport.onResponseDone = { [weak self] in
            guard let self else { return }
            if state.activity == .processing { state.activity = .listening }
        }
        transport.onSpeechStarted = { [weak self] in
            self?.state.transcript = ""
            self?.state.aiReply = ""
        }
    }

    // MARK: - Public

    func activate() {
        guard !state.isActive else { return }
        guard let apiKey = VoiceKeychainStore.load(), !apiKey.isEmpty else {
            #if DEBUG
            cmuxDebugLog("voice.activate.noKey")
            #endif
            state.activity = .error("No API key set — open Settings > Voice to add your OpenAI key.")
            showHUD()
            return
        }
        #if DEBUG
        cmuxDebugLog("voice.activate keyLen=\(apiKey.count)")
        #endif
        state.isActive = true
        state.activity = .connecting
        showHUD()
        transport.connect(apiKey: apiKey)
        startAudioCapture()
    }

    func deactivate() {
        stopAudioCapture()
        transport.disconnect()
        state.isActive = false
        state.activity = .idle
        state.transcript = ""
        state.aiReply = ""
        hideHUD()
    }

    func toggle() {
        #if DEBUG
        cmuxDebugLog("voice.toggle isActive=\(state.isActive) activity=\(state.activity)")
        #endif
        if state.isActive { deactivate() } else { activate() }
    }

    // MARK: - Audio

    private func startAudioCapture() {
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if permissionStatus == .denied || permissionStatus == .restricted {
            state.activity = .error("Microphone access denied. Please enable it in System Settings.")
            return
        }
        if permissionStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.startAudioCapture()
                    } else {
                        self?.state.activity = .error("Microphone access denied.")
                    }
                }
            }
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            state.activity = .error("Audio format conversion not available.")
            return
        }
        // Capture conv and targetFormat locally so the tap closure (background thread)
        // never touches @MainActor-isolated properties.
        let localTargetFormat = targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self, conv] buffer, _ in
            guard let raw = Self.convertPCM(buffer, using: conv, targetFormat: localTargetFormat) else { return }
            Task { @MainActor [weak self] in
                self?.transport.send(.audioAppend(raw))
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            state.activity = .listening
        } catch {
            state.activity = .error("Microphone start failed: \(error.localizedDescription)")
        }
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // Static: called from background tap thread — no self access allowed.
    private static func convertPCM(
        _ inputBuffer: AVAudioPCMBuffer,
        using conv: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> Data? {
        let capacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputBuffer.format.sampleRate + 1
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        var error: NSError?
        var inputConsumed = false
        conv.convert(to: outputBuffer, error: &error) { _, status in
            if inputConsumed {
                status.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else { return nil }

        let frameCount = Int(outputBuffer.frameLength)
        return Data(bytes: channelData[0], count: frameCount * 2)
    }

    // MARK: - Tool calls

    private func handleToolCall(_ call: VoiceToolCall) {
        state.activity = .executing
        state.aiReply = ""
        let result = executor.execute(call: call)
        state.lastAction = formatAction(call)
        transport.send(.functionCallOutput(callId: call.callId, output: result))
        transport.send(.responseCreate)
        state.activity = .listening
    }

    private func formatAction(_ call: VoiceToolCall) -> String {
        switch call.name {
        case "execute_command":
            if let cmd = extractArg("command", from: call.arguments) { return "Ran: \(cmd)" }
        case "type_text":
            if let text = extractArg("text", from: call.arguments) { return "Typed: \(text)" }
        case "switch_workspace":
            return "Switched workspace"
        case "switch_tab":
            return "Switched tab"
        case "get_app_state":
            return "Checked app state"
        case "create_workspace":
            if let name = extractArg("name", from: call.arguments) { return "Created workspace: \(name)" }
            return "Created workspace"
        case "close_workspace":
            return "Closed workspace"
        case "rename_workspace":
            if let name = extractArg("name", from: call.arguments) { return "Renamed to: \(name)" }
            return "Renamed workspace"
        default: break
        }
        return call.name
    }

    private func extractArg(_ key: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String
        else { return nil }
        return value
    }

    // MARK: - HUD

    private func showHUD() {
        if hudPanel == nil {
            let hosting = NSHostingView(rootView: VoiceHUDView(state: state))
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 300)

            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level.floating
            panel.backgroundColor = NSColor.clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.contentView = hosting

            if let screen = NSScreen.main {
                let x = screen.visibleFrame.midX - 160
                let y = screen.visibleFrame.minY + 60
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            hudPanel = panel
        }
        hudPanel?.orderFront(nil)
    }

    private func hideHUD() {
        hudPanel?.orderOut(nil)
    }

    // MARK: - Transport state

    private func handleTransportStateChange(_ connectionState: VoiceRealtimeTransport.ConnectionState) {
        switch connectionState {
        case .connected:
            if state.activity == .connecting { state.activity = .listening }
        case .failed(let error):
            state.activity = .error(error.localizedDescription)
            state.isActive = false
            stopAudioCapture()
            transport.disconnect()
        case .disconnected:
            if state.isActive {
                stopAudioCapture()
                state.isActive = false
                state.activity = .idle
                transport.disconnect()
            }
        case .connecting:
            state.activity = .connecting
        }
    }
}
