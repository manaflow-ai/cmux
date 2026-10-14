import AVFoundation
import Foundation

/// 16-bit mono PCM WAV encoding, the format audio messages travel in here
/// (the simulator serves procedural WAV, and recordings are re-encoded so a
/// continued recording concatenates without a transcode).
public enum ConversationWAV {
    public static let sampleRate = 16_000

    public static func encode(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    /// Decodes any file AVFoundation reads into mono samples at `sampleRate`.
    public static func decode(contentsOf url: URL, sampleRate: Int = sampleRate) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { return [] }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * Double(sampleRate) / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let pending = input
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return pending
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Peak level per `bucket` of samples, normalized so loud speech nears 1.
    public static func levels(_ samples: [Float], bucket: Int) -> [Float] {
        guard bucket > 0, !samples.isEmpty else { return [] }
        var result: [Float] = []
        result.reserveCapacity(samples.count / bucket + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + bucket)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            result.append(meterLevel(rms: (sum / Float(end - index)).squareRoot()))
            index = end
        }
        return result
    }

    /// Maps an RMS amplitude to the 0...1 bar height Messages-style meters use
    /// (logarithmic, with a floor so silence still draws a dot).
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return meterLevel(decibels: 20 * log10(rms))
    }

    public static func meterLevel(decibels: Float) -> Float {
        let floor: Float = -50
        guard decibels > floor else { return 0 }
        return min(1, (decibels - floor) / -floor)
    }
}

/// Speech-like procedural audio (voiced syllables with pauses) for the
/// simulator path when no microphone is available. Deterministic per seed.
public enum ConversationSyntheticSpeech {
    public static func samples(seconds: Double, seed: UInt64, sampleRate: Int = ConversationWAV.sampleRate) -> [Float] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let count = Int(seconds * Double(sampleRate))
        var output = [Float](repeating: 0, count: count)
        var position = 0
        var phase: Float = 0
        while position < count {
            // A syllable 90-260 ms, then a gap 30-120 ms (longer pauses sometimes).
            let syllable = Int((0.09 + 0.17 * Double(random())) * Double(sampleRate))
            let gap = Int((random() < 0.15 ? 0.25 + 0.3 * Double(random()) : 0.03 + 0.09 * Double(random())) * Double(sampleRate))
            let pitch = 110 + 90 * random()
            let loudness = 0.25 + 0.6 * random()
            for i in 0..<syllable where position + i < count {
                let t = Float(i) / Float(syllable)
                let envelope = sin(Float.pi * t) * loudness
                phase += 2 * Float.pi * pitch / Float(sampleRate)
                var value = sin(phase) * 0.6 + sin(2 * phase) * 0.25 + sin(3 * phase) * 0.12
                value += (random() - 0.5) * 0.08
                output[position + i] = value * envelope
            }
            position += syllable + gap
        }
        return output
    }
}

/// What finishing a recording yields.
public struct ConversationRecordedAudio: Sendable {
    public var data: Data
    public var info: ConversationAudioInfo
}

/// Records an audio message: live levels for the composer's meter, pause
/// for review, continue recording, then one WAV. The microphone is the
/// default input; `CMUX_CONVERSATION_AUDIO_INPUT=synthetic` or a file path
/// replays that audio in real time instead (simulators without a mic).
@MainActor
public final class ConversationAudioRecorder: NSObject {
    public enum State: Equatable {
        case idle
        case recording
        /// Stopped for review; `continueRecording()` appends.
        case paused
    }

    public enum Input: Equatable {
        case microphone
        case synthetic
        case file(URL)

        public static var fromEnvironment: Input {
            guard let raw = ProcessInfo.processInfo.environment["CMUX_CONVERSATION_AUDIO_INPUT"], !raw.isEmpty else {
                return .microphone
            }
            return raw == "synthetic" ? .synthetic : .file(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
    }

    public private(set) var state: State = .idle
    /// One level per `levelInterval` of recorded audio, 0...1.
    public private(set) var levels: [Float] = []
    public static let levelInterval: TimeInterval = 0.05
    public let input: Input
    /// The transcript a synthetic input "says" (there is no speech to recognize).
    public var syntheticTranscript: String?

    private var committed: [Float] = []
    private var segmentStart: Date?
    private var recorder: AVAudioRecorder?
    private var segmentURL: URL?
    private var replay: [Float] = []
    private var replayOffset = 0

    public init(input: Input = .fromEnvironment) {
        self.input = input
    }

    /// Recorded time, including the segment in progress.
    public var duration: TimeInterval {
        Double(committed.count) / Double(ConversationWAV.sampleRate) + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    public func start() async throws {
        guard state == .idle else { return }
        committed = []
        levels = []
        switch input {
        case .microphone:
            guard await Self.requestPermission() else {
                throw ConversationBackendError(code: -10, message: "microphone access denied")
            }
        case .synthetic:
            replay = ConversationSyntheticSpeech.samples(seconds: 60, seed: UInt64(Date().timeIntervalSince1970))
        case let .file(url):
            replay = try ConversationWAV.decode(contentsOf: url)
        }
        replayOffset = 0
        try beginSegment()
    }

    public func continueRecording() throws {
        guard state == .paused else { return }
        try beginSegment()
    }

    private func beginSegment() throws {
        if input == .microphone {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-audio-\(UUID().uuidString).wav")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: ConversationWAV.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw ConversationBackendError(code: -11, message: "microphone unavailable")
            }
            self.recorder = recorder
            segmentURL = url
        }
        segmentStart = Date()
        state = .recording
    }

    /// Called every display frame while recording; appends levels for the
    /// time elapsed since the last call. Returns true when levels changed.
    @discardableResult
    public func tick() -> Bool {
        guard state == .recording else { return false }
        let wanted = Int(duration / Self.levelInterval)
        guard wanted > levels.count else { return false }
        while levels.count < wanted {
            levels.append(currentLevel(at: Double(levels.count) * Self.levelInterval))
        }
        return true
    }

    private func currentLevel(at time: TimeInterval) -> Float {
        if let recorder {
            recorder.updateMeters()
            return ConversationWAV.meterLevel(decibels: recorder.peakPower(forChannel: 0))
        }
        let start = Int(time * Double(ConversationWAV.sampleRate))
        let bucket = Int(Self.levelInterval * Double(ConversationWAV.sampleRate))
        guard !replay.isEmpty else { return 0 }
        let window = (0..<bucket).map { replay[(start + $0) % replay.count] }
        return ConversationWAV.levels(window, bucket: bucket).first ?? 0
    }

    /// Stops the current segment for review.
    public func pause() {
        guard state == .recording else { return }
        tick()
        finishSegment()
        state = .paused
    }

    private func finishSegment() {
        let elapsed = segmentStart.map { Date().timeIntervalSince($0) } ?? 0
        segmentStart = nil
        if let recorder, let url = segmentURL {
            recorder.stop()
            self.recorder = nil
            committed += (try? ConversationWAV.decode(contentsOf: url)) ?? []
            try? FileManager.default.removeItem(at: url)
            segmentURL = nil
        } else {
            let count = Int(elapsed * Double(ConversationWAV.sampleRate))
            for _ in 0..<count {
                committed.append(replay.isEmpty ? 0 : replay[replayOffset % replay.count])
                replayOffset += 1
            }
        }
        // Keep the meter in step with the audio actually kept.
        let wanted = Int((Double(committed.count) / Double(ConversationWAV.sampleRate)) / Self.levelInterval)
        if levels.count > wanted { levels.removeLast(levels.count - wanted) }
        while levels.count < wanted { levels.append(levels.last ?? 0) }
    }

    /// The recording so far (for review playback while paused).
    public var reviewData: Data { ConversationWAV.encode(committed) }

    /// Finishes and returns the message payload, or nil when nothing was recorded.
    public func finish() -> ConversationRecordedAudio? {
        if state == .recording { finishSegment() }
        defer { reset() }
        guard committed.count > ConversationWAV.sampleRate / 4 else { return nil }
        let info = ConversationAudioInfo(
            duration: Double(committed.count) / Double(ConversationWAV.sampleRate),
            waveform: ConversationAudioInfo.resample(levels, count: min(levels.count, 120)),
            transcript: input == .microphone ? nil : syntheticTranscript
        )
        return ConversationRecordedAudio(data: ConversationWAV.encode(committed), info: info)
    }

    public func cancel() {
        recorder?.stop()
        if let url = segmentURL { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    private func reset() {
        recorder = nil
        segmentURL = nil
        segmentStart = nil
        committed = []
        levels = []
        replay = []
        state = .idle
    }
}

/// Plays audio messages: one at a time, resumable per message, with
/// scrubbing and auto-advance to the next consecutive incoming recording.
@MainActor
public final class ConversationAudioPlayer: NSObject, AVAudioPlayerDelegate {
    public static let shared = ConversationAudioPlayer()

    /// The message whose recording is loaded (playing or paused).
    public private(set) var currentID: String?
    public private(set) var isPlaying = false
    /// The message whose recording is being fetched.
    public private(set) var loadingID: String?
    /// Resume points of messages paused or scrubbed while another played.
    private var positions: [String: TimeInterval] = [:]
    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]
    private var loadTask: Task<Void, Never>?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    /// Returns the audio message to play after `messageID` finishes, if any.
    public var nextMessage: (@MainActor (String) -> ConversationMessage?)?
    /// A message finished playing to its end.
    public var onFinished: (@MainActor (String) -> Void)?

    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func changed() {
        for observer in observers.values { observer() }
    }

    public func isPlaying(_ messageID: String) -> Bool {
        isPlaying && currentID == messageID
    }

    /// Seconds into `messageID`'s recording.
    public func position(for messageID: String) -> TimeInterval {
        if currentID == messageID, let player { return player.currentTime }
        return positions[messageID] ?? 0
    }

    /// 0...1 progress through `messageID`'s recording.
    public func progress(for message: ConversationMessage) -> Double {
        let duration = playerDuration(for: message)
        guard duration > 0 else { return 0 }
        return min(1, max(0, position(for: message.id) / duration))
    }

    private func playerDuration(for message: ConversationMessage) -> TimeInterval {
        if currentID == message.id, let player, player.duration > 0 { return player.duration }
        return message.audioAttachment?.audio?.duration ?? 0
    }

    public func toggle(_ message: ConversationMessage) {
        if isPlaying(message.id) {
            pause()
        } else {
            play(message)
        }
    }

    public func pause() {
        guard let player, let currentID else { return }
        player.pause()
        positions[currentID] = player.currentTime
        isPlaying = false
        changed()
    }

    public func stop() {
        loadTask?.cancel()
        loadTask = nil
        loadingID = nil
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        changed()
    }

    /// Moves `message`'s playhead to `fraction` of its length. Playback
    /// continues if it was playing.
    public func seek(_ message: ConversationMessage, to fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let time = clamped * playerDuration(for: message)
        if currentID == message.id, let player {
            player.currentTime = min(time, max(0, player.duration - 0.01))
        } else {
            positions[message.id] = time
        }
        changed()
    }

    public func play(_ message: ConversationMessage) {
        guard let attachment = message.audioAttachment else { return }
        if currentID == message.id, let player {
            activateSession()
            if player.currentTime >= player.duration - 0.02 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            changed()
            return
        }
        if let current = currentID, let player {
            player.stop()
            positions[current] = player.currentTime
            self.player = nil
        }
        isPlaying = false
        currentID = message.id
        loadTask?.cancel()
        if let data = attachment.localData ?? cache[attachment.id] {
            start(message, data: data)
            return
        }
        guard let url = attachment.url else { return }
        loadingID = message.id
        changed()
        let messageID = message.id
        loadTask = Task { [weak self] in
            let data = try? await URLSession.shared.data(from: url).0
            guard let self, !Task.isCancelled, self.currentID == messageID else { return }
            self.loadingID = nil
            guard let data else {
                self.currentID = nil
                self.changed()
                return
            }
            self.cache[attachment.id] = data
            self.start(message, data: data)
        }
    }

    private func start(_ message: ConversationMessage, data: Data) {
        guard let player = try? AVAudioPlayer(data: data) else {
            currentID = nil
            changed()
            return
        }
        player.delegate = self
        player.prepareToPlay()
        let resume = positions.removeValue(forKey: message.id) ?? 0
        player.currentTime = resume >= player.duration - 0.05 ? 0 : resume
        activateSession()
        self.player = player
        player.play()
        isPlaying = true
        changed()
    }

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio)
        }
        try? session.setActive(true)
        #endif
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.didFinish(finished) }
    }

    private func didFinish(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished, let messageID = currentID else { return }
        positions[messageID] = 0
        self.player = nil
        currentID = nil
        isPlaying = false
        onFinished?(messageID)
        if let next = nextMessage?(messageID) {
            positions[next.id] = 0
            play(next)
        } else {
            changed()
        }
    }
}
