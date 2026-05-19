import AppKit
import AVFoundation
import Foundation
import SwiftUI

enum GeminiVoiceWindow {
    static let windowID = "gemini-voice"
}

struct GeminiVoiceCorrectionExample: Equatable {
    let transcript: String
    let correction: String
}

struct GeminiVoiceSessionRecord: Codable, Equatable, Identifiable {
    enum Status: String, Codable, Equatable {
        case recorded
        case transcribing
        case completed
        case failed

        var localizedTitle: String {
            switch self {
            case .recorded:
                return String(localized: "geminiVoice.status.recorded", defaultValue: "Recorded")
            case .transcribing:
                return String(localized: "geminiVoice.status.transcribing", defaultValue: "Calling Gemini")
            case .completed:
                return String(localized: "geminiVoice.status.completed", defaultValue: "Complete")
            case .failed:
                return String(localized: "geminiVoice.status.failed", defaultValue: "Failed")
            }
        }
    }

    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var status: Status
    var model: String
    var mimeType: String
    var audioFileName: String
    var requestFileName: String?
    var responseFileName: String?
    var durationSeconds: TimeInterval?
    var inputPrompt: String
    var transcript: String
    var correction: String
    var rawResponseText: String
    var errorMessage: String?

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        status: Status,
        model: String,
        mimeType: String,
        audioFileName: String,
        requestFileName: String? = nil,
        responseFileName: String? = nil,
        durationSeconds: TimeInterval? = nil,
        inputPrompt: String = "",
        transcript: String = "",
        correction: String = "",
        rawResponseText: String = "",
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.model = model
        self.mimeType = mimeType
        self.audioFileName = audioFileName
        self.requestFileName = requestFileName
        self.responseFileName = responseFileName
        self.durationSeconds = durationSeconds
        self.inputPrompt = inputPrompt
        self.transcript = transcript
        self.correction = correction
        self.rawResponseText = rawResponseText
        self.errorMessage = errorMessage
    }

    var correctionExample: GeminiVoiceCorrectionExample? {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCorrection = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty, !normalizedCorrection.isEmpty else { return nil }
        return GeminiVoiceCorrectionExample(
            transcript: normalizedTranscript,
            correction: normalizedCorrection
        )
    }
}

actor GeminiVoiceSessionStore {
    private struct FileNames {
        static let sessions = "sessions.json"
        static let audio = "audio"
        static let requests = "requests"
        static let responses = "responses"
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL = GeminiVoiceSessionStore.defaultRootDirectory(), fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    static func defaultRootDirectory(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("gemini-voice", isDirectory: true)
    }

    var storageDirectory: URL {
        rootDirectory
    }

    func load() throws -> [GeminiVoiceSessionRecord] {
        try ensureDirectories()
        let url = sessionsURL
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GeminiVoiceSessionRecord].self, from: data)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ records: [GeminiVoiceSessionRecord]) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.sorted { $0.createdAt > $1.createdAt })
        try data.write(to: sessionsURL, options: [.atomic])
    }

    func audioURL(for id: UUID) throws -> URL {
        try ensureDirectories()
        return audioDirectory.appendingPathComponent("\(id.uuidString).wav", isDirectory: false)
    }

    func writeRequest(_ data: Data, id: UUID) throws -> String {
        try ensureDirectories()
        let fileName = "\(id.uuidString).json"
        try data.write(to: requestDirectory.appendingPathComponent(fileName), options: [.atomic])
        return "\(FileNames.requests)/\(fileName)"
    }

    func writeResponse(_ data: Data, id: UUID) throws -> String {
        try ensureDirectories()
        let fileName = "\(id.uuidString).json"
        try data.write(to: responseDirectory.appendingPathComponent(fileName), options: [.atomic])
        return "\(FileNames.responses)/\(fileName)"
    }

    func readData(relativePath: String) throws -> Data {
        try Data(contentsOf: rootDirectory.appendingPathComponent(relativePath, isDirectory: false))
    }

    func absoluteURL(forRelativePath relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath, isDirectory: false)
    }

    private var sessionsURL: URL {
        rootDirectory.appendingPathComponent(FileNames.sessions, isDirectory: false)
    }

    private var audioDirectory: URL {
        rootDirectory.appendingPathComponent(FileNames.audio, isDirectory: true)
    }

    private var requestDirectory: URL {
        rootDirectory.appendingPathComponent(FileNames.requests, isDirectory: true)
    }

    private var responseDirectory: URL {
        rootDirectory.appendingPathComponent(FileNames.responses, isDirectory: true)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: requestDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: responseDirectory, withIntermediateDirectories: true)
    }
}

struct GeminiVoiceAPIKeyResolver {
    struct ResolvedAPIKey: Equatable {
        enum Source: Equatable {
            case environment(String)
            case file(URL, String)
        }

        let value: String
        let source: Source

        var displayName: String {
            switch source {
            case .environment(let name):
                return name
            case .file(let url, let name):
                return "\(url.path) (\(name))"
            }
        }
    }

    static let supportedVariableNames = [
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_AI_API_KEY",
    ]

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ResolvedAPIKey? {
        for name in supportedVariableNames {
            if let value = normalized(environment[name]) {
                return ResolvedAPIKey(value: value, source: .environment(name))
            }
        }

        let candidateFiles = [
            homeDirectory.appendingPathComponent(".secrets/cmux.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".claude/.env", isDirectory: false),
            homeDirectory.appendingPathComponent(".claude/settings.json", isDirectory: false),
        ]

        for fileURL in candidateFiles where fileManager.fileExists(atPath: fileURL.path) {
            if fileURL.pathExtension == "json",
               let resolved = resolveJSONFile(fileURL: fileURL) {
                return resolved
            }
            if let resolved = resolveEnvFile(fileURL: fileURL) {
                return resolved
            }
        }

        return nil
    }

    static func parseEnvFile(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            } else if let commentStart = value.firstIndex(of: "#") {
                value = String(value[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !key.isEmpty, let normalizedValue = normalized(value) {
                result[key] = normalizedValue
            }
        }
        return result
    }

    private static func resolveEnvFile(fileURL: URL) -> ResolvedAPIKey? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let values = parseEnvFile(contents)
        for name in supportedVariableNames {
            if let value = normalized(values[name]) {
                return ResolvedAPIKey(value: value, source: .file(fileURL, name))
            }
        }
        return nil
    }

    private static func resolveJSONFile(fileURL: URL) -> ResolvedAPIKey? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        for name in supportedVariableNames {
            if let value = normalized(object[name] as? String) {
                return ResolvedAPIKey(value: value, source: .file(fileURL, name))
            }
        }

        if let env = object["env"] as? [String: Any] {
            for name in supportedVariableNames {
                if let value = normalized(env[name] as? String) {
                    return ResolvedAPIKey(value: value, source: .file(fileURL, name))
                }
            }
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum GeminiVoicePromptBuilder {
    static func correctionExamples(from records: [GeminiVoiceSessionRecord]) -> [GeminiVoiceCorrectionExample] {
        records
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(\.correctionExample)
    }

    static func makeTranscriptionPrompt(correctionExamples: [GeminiVoiceCorrectionExample]) -> String {
        var prompt = """
        You are the transcription engine for a voice-to-text correction workflow.
        Transcribe the provided audio exactly as text.
        Return only the transcript text for the new audio.
        Preserve intentional wording, names, technical terms, punctuation style, and casing.
        """

        guard !correctionExamples.isEmpty else { return prompt }

        prompt += "\n\nUse these prior correction examples as context for this user:\n"
        for (index, example) in correctionExamples.enumerated() {
            prompt += """

            Example \(index + 1)
            Gemini transcript:
            \(example.transcript)

            Corrected transcript:
            \(example.correction)
            """
        }
        return prompt
    }
}

struct GeminiVoicePreparedRequest {
    let urlRequest: URLRequest
    let bodyData: Data
}

struct GeminiVoiceTranscriptionResult {
    let transcript: String
    let responseData: Data
    let rawResponseText: String
}

struct GeminiVoiceAPIRequestFailure: LocalizedError {
    let statusCode: Int
    let message: String
    let responseData: Data

    var errorDescription: String? {
        String(
            format: String(localized: "geminiVoice.error.http", defaultValue: "Gemini returned HTTP %lld: %@"),
            statusCode,
            message
        )
    }
}

enum GeminiVoiceClientError: LocalizedError {
    case missingTranscript
    case invalidModel
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingTranscript:
            return String(localized: "geminiVoice.error.missingTranscript", defaultValue: "Gemini returned no transcript text.")
        case .invalidModel:
            return String(localized: "geminiVoice.error.invalidModel", defaultValue: "Enter a Gemini model name.")
        case .invalidResponse:
            return String(localized: "geminiVoice.error.invalidResponse", defaultValue: "Gemini returned an invalid response.")
        }
    }
}

struct GeminiVoiceClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func prepareRequest(
        audioData: Data,
        mimeType: String,
        model: String,
        prompt: String,
        apiKey: String
    ) throws -> GeminiVoicePreparedRequest {
        let normalizedModel = try Self.normalizedModelName(model)
        let requestBody = GeminiGenerateContentRequest(
            contents: [
                GeminiGenerateContentRequest.Content(
                    role: "user",
                    parts: [
                        .text(prompt),
                        .inlineData(mimeType: mimeType, data: audioData.base64EncodedString()),
                    ]
                ),
            ]
        )
        let bodyData = try encoder.encode(requestBody)

        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(normalizedModel):generateContent"
        ) else {
            throw GeminiVoiceClientError.invalidModel
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        return GeminiVoicePreparedRequest(urlRequest: request, bodyData: bodyData)
    }

    func send(_ preparedRequest: GeminiVoicePreparedRequest) async throws -> GeminiVoiceTranscriptionResult {
        let (data, response) = try await session.data(for: preparedRequest.urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiVoiceClientError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            let message = Self.errorMessage(from: data)
            throw GeminiVoiceAPIRequestFailure(
                statusCode: httpResponse.statusCode,
                message: message,
                responseData: data
            )
        }

        let decoded = try decoder.decode(GeminiGenerateContentResponse.self, from: data)
        let transcript = decoded.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw GeminiVoiceClientError.missingTranscript
        }

        return GeminiVoiceTranscriptionResult(
            transcript: transcript,
            responseData: data,
            rawResponseText: String(data: data, encoding: .utf8) ?? ""
        )
    }

    static func normalizedModelName(_ model: String) throws -> String {
        var normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("models/") {
            normalized.removeFirst("models/".count)
        }
        guard !normalized.isEmpty,
              let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !encoded.isEmpty else {
            throw GeminiVoiceClientError.invalidModel
        }
        return encoded
    }

    private static func errorMessage(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data),
           let message = decoded.error.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "geminiVoice.error.unknownHTTPBody", defaultValue: "No response body")
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    enum Part: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData
        }

        struct InlineData: Encodable {
            let mimeType: String
            let data: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .text)
            case .inlineData(let mimeType, let data):
                try container.encode(InlineData(mimeType: mimeType, data: data), forKey: .inlineData)
            }
        }
    }

    let contents: [Content]
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?

    var transcriptText: String {
        candidates?
            .compactMap { candidate in
                candidate.content?.parts?
                    .compactMap(\.text)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n") ?? ""
    }
}

private struct GeminiErrorResponse: Decodable {
    struct APIError: Decodable {
        let code: Int?
        let message: String
        let status: String?
    }

    let error: APIError
}

struct GeminiVoiceAudioRecordingResult {
    let url: URL
    let durationSeconds: TimeInterval
}

final class GeminiVoiceAudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeURL: URL?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func startRecording(to url: URL) async throws {
        try await Self.requestMicrophoneAccess()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = false
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw GeminiVoiceRecorderError.failedToStart
        }
        self.recorder = recorder
        self.activeURL = url
    }

    func stopRecording() throws -> GeminiVoiceAudioRecordingResult {
        guard let recorder, let activeURL else {
            throw GeminiVoiceRecorderError.noActiveRecording
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.activeURL = nil
        return GeminiVoiceAudioRecordingResult(url: activeURL, durationSeconds: duration)
    }

    private static func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted { return }
            throw GeminiVoiceRecorderError.microphoneDenied
        case .denied, .restricted:
            throw GeminiVoiceRecorderError.microphoneDenied
        @unknown default:
            throw GeminiVoiceRecorderError.microphoneDenied
        }
    }
}

enum GeminiVoiceRecorderError: LocalizedError {
    case microphoneDenied
    case failedToStart
    case noActiveRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return String(localized: "geminiVoice.error.microphoneDenied", defaultValue: "Microphone permission is required.")
        case .failedToStart:
            return String(localized: "geminiVoice.error.recordingFailed", defaultValue: "Recording could not start.")
        case .noActiveRecording:
            return String(localized: "geminiVoice.error.noActiveRecording", defaultValue: "No active recording.")
        }
    }
}

@MainActor
final class GeminiVoiceViewModel: ObservableObject {
    static let defaultModel = "gemini-3-flash-preview"
    private static let modelDefaultsKey = "geminiVoice.model"

    @Published private(set) var sessions: [GeminiVoiceSessionRecord] = []
    @Published var selectedSessionID: UUID? {
        didSet {
            if oldValue != selectedSessionID {
                correctionDraft = selectedSession?.correction ?? ""
            }
        }
    }
    @Published var model: String {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.modelDefaultsKey)
        }
    }
    @Published var correctionDraft = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var statusMessage = String(localized: "geminiVoice.status.ready", defaultValue: "Ready")
    @Published private(set) var errorMessage: String?
    @Published private(set) var apiKeyStatus = String(localized: "geminiVoice.status.apiKeyUnchecked", defaultValue: "API key not checked")

    private let store: GeminiVoiceSessionStore
    private let recorder: GeminiVoiceAudioRecorder
    private let client: GeminiVoiceClient
    private var currentRecordingID: UUID?

    init(
        store: GeminiVoiceSessionStore = GeminiVoiceSessionStore(),
        recorder: GeminiVoiceAudioRecorder = GeminiVoiceAudioRecorder(),
        client: GeminiVoiceClient = GeminiVoiceClient()
    ) {
        self.store = store
        self.recorder = recorder
        self.client = client
        self.model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
    }

    var selectedSession: GeminiVoiceSessionRecord? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var canRetrySelectedSession: Bool {
        selectedSession != nil && !isRecording && !isTranscribing
    }

    func load() async {
        do {
            sessions = try await store.load()
            if selectedSessionID == nil {
                selectedSessionID = sessions.first?.id
            }
            correctionDraft = selectedSession?.correction ?? ""
            refreshAPIKeyStatus()
        } catch {
            showError(error)
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func retrySelectedSession() {
        guard let selectedSessionID else { return }
        Task { await transcribe(recordID: selectedSessionID) }
    }

    func saveCorrection() {
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            return
        }
        sessions[index].correction = correctionDraft
        sessions[index].updatedAt = Date()
        Task {
            do {
                try await store.save(sessions)
                statusMessage = String(localized: "geminiVoice.status.correctionSaved", defaultValue: "Correction saved")
                errorMessage = nil
            } catch {
                showError(error)
            }
        }
    }

    func revealStorageDirectory() {
        Task {
            let url = await store.storageDirectory
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func startRecording() async {
        do {
            let id = UUID()
            let audioURL = try await store.audioURL(for: id)
            try await recorder.startRecording(to: audioURL)
            currentRecordingID = id
            isRecording = true
            errorMessage = nil
            statusMessage = String(localized: "geminiVoice.status.recording", defaultValue: "Recording")
        } catch {
            showError(error)
        }
    }

    private func stopRecording() async {
        do {
            let recording = try recorder.stopRecording()
            guard let id = currentRecordingID else {
                throw GeminiVoiceRecorderError.noActiveRecording
            }
            currentRecordingID = nil
            isRecording = false

            let now = Date()
            let record = GeminiVoiceSessionRecord(
                id: id,
                createdAt: now,
                updatedAt: now,
                status: .recorded,
                model: model,
                mimeType: "audio/wav",
                audioFileName: "audio/\(recording.url.lastPathComponent)",
                durationSeconds: recording.durationSeconds
            )
            sessions.insert(record, at: 0)
            selectedSessionID = id
            correctionDraft = ""
            try await store.save(sessions)
            await transcribe(recordID: id)
        } catch {
            isRecording = false
            currentRecordingID = nil
            showError(error)
        }
    }

    private func transcribe(recordID: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == recordID }) else { return }
        guard let apiKey = GeminiVoiceAPIKeyResolver.resolve() else {
            let message = String(
                localized: "geminiVoice.error.noAPIKey",
                defaultValue: "Set GEMINI_API_KEY or GOOGLE_API_KEY in the environment or ~/.secrets/cmux.env."
            )
            updateRecord(recordID: recordID) { record in
                record.status = .failed
                record.errorMessage = message
                record.updatedAt = Date()
            }
            await saveSessionsAfterMutation()
            refreshAPIKeyStatus()
            statusMessage = String(localized: "geminiVoice.status.failed", defaultValue: "Failed")
            errorMessage = message
            return
        }

        do {
            refreshAPIKeyStatus(apiKey)
            isTranscribing = true
            statusMessage = String(localized: "geminiVoice.status.transcribing", defaultValue: "Calling Gemini")
            errorMessage = nil

            let record = sessions[index]
            let audioData = try await store.readData(relativePath: record.audioFileName)
            let correctionExamples = GeminiVoicePromptBuilder.correctionExamples(from: sessions.filter { $0.id != recordID })
            let prompt = GeminiVoicePromptBuilder.makeTranscriptionPrompt(correctionExamples: correctionExamples)
            let prepared = try client.prepareRequest(
                audioData: audioData,
                mimeType: record.mimeType,
                model: model,
                prompt: prompt,
                apiKey: apiKey.value
            )
            let requestFileName = try await store.writeRequest(prepared.bodyData, id: recordID)
            updateRecord(recordID: recordID) { record in
                record.status = .transcribing
                record.model = model
                record.inputPrompt = prompt
                record.requestFileName = requestFileName
                record.updatedAt = Date()
                record.errorMessage = nil
            }
            try await store.save(sessions)

            do {
                let result = try await client.send(prepared)
                let responseFileName = try await store.writeResponse(result.responseData, id: recordID)
                updateRecord(recordID: recordID) { record in
                    record.status = .completed
                    record.transcript = result.transcript
                    record.rawResponseText = result.rawResponseText
                    record.responseFileName = responseFileName
                    record.updatedAt = Date()
                    record.errorMessage = nil
                }
                statusMessage = String(localized: "geminiVoice.status.completed", defaultValue: "Complete")
            } catch let apiFailure as GeminiVoiceAPIRequestFailure {
                let responseFileName = try await store.writeResponse(apiFailure.responseData, id: recordID)
                updateRecord(recordID: recordID) { record in
                    record.status = .failed
                    record.responseFileName = responseFileName
                    record.errorMessage = apiFailure.localizedDescription
                    record.updatedAt = Date()
                }
                throw apiFailure
            }
            try await store.save(sessions)
            if selectedSessionID == recordID, correctionDraft.isEmpty {
                correctionDraft = selectedSession?.correction ?? ""
            }
        } catch {
            updateRecord(recordID: recordID) { record in
                record.status = .failed
                record.errorMessage = error.localizedDescription
                record.updatedAt = Date()
            }
            await saveSessionsAfterMutation()
            showError(error)
        }
        isTranscribing = false
    }

    private func saveSessionsAfterMutation() async {
        do {
            try await store.save(sessions)
        } catch {
            showError(error)
        }
    }

    private func updateRecord(recordID: UUID, mutation: (inout GeminiVoiceSessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == recordID }) else { return }
        mutation(&sessions[index])
    }

    private func refreshAPIKeyStatus(_ resolved: GeminiVoiceAPIKeyResolver.ResolvedAPIKey? = GeminiVoiceAPIKeyResolver.resolve()) {
        if let resolved {
            apiKeyStatus = String(
                format: String(localized: "geminiVoice.status.apiKeyLoaded", defaultValue: "API key loaded from %@"),
                resolved.displayName
            )
        } else {
            apiKeyStatus = String(localized: "geminiVoice.status.apiKeyMissing", defaultValue: "API key missing")
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = String(localized: "geminiVoice.status.failed", defaultValue: "Failed")
    }
}

struct GeminiVoiceView: View {
    @StateObject private var viewModel = GeminiVoiceViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sessionList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleRecording()
            } label: {
                Label(
                    viewModel.isRecording
                        ? String(localized: "geminiVoice.stop", defaultValue: "Stop")
                        : String(localized: "geminiVoice.record", defaultValue: "Record"),
                    systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill"
                )
            }
            .disabled(viewModel.isTranscribing)

            Button {
                viewModel.retrySelectedSession()
            } label: {
                Label(String(localized: "geminiVoice.retry", defaultValue: "Retry Gemini"), systemImage: "arrow.clockwise")
            }
            .disabled(!viewModel.canRetrySelectedSession)

            Button {
                viewModel.revealStorageDirectory()
            } label: {
                Label(String(localized: "geminiVoice.revealFiles", defaultValue: "Reveal Files"), systemImage: "folder")
            }

            Divider()

            Text(String(localized: "geminiVoice.model", defaultValue: "Model"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(String(localized: "geminiVoice.model", defaultValue: "Model"), text: $viewModel.model)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: viewModel.statusMessage)
                    .font(.callout)
                Text(verbatim: viewModel.apiKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "geminiVoice.sessions", defaultValue: "Sessions"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if viewModel.sessions.isEmpty {
                Spacer()
                Text(String(localized: "geminiVoice.noRecordings", defaultValue: "No recordings yet"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(selection: $viewModel.selectedSessionID) {
                    ForEach(viewModel.sessions) { record in
                        GeminiVoiceSessionRow(record: record)
                            .tag(record.id as UUID?)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = viewModel.selectedSession {
            VStack(alignment: .leading, spacing: 12) {
                detailHeader(record)
                HSplitView {
                    transcriptSection(record)
                        .frame(minHeight: 160)
                    correctionSection
                        .frame(minHeight: 160)
                }
                if let error = record.errorMessage ?? viewModel.errorMessage {
                    Text(verbatim: error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text(String(localized: "geminiVoice.noSelection", defaultValue: "Select a recording"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func detailHeader(_ record: GeminiVoiceSessionRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Text(verbatim: record.status.localizedTitle)
                    if let duration = record.durationSeconds {
                        Text(verbatim: String(format: "%.1fs", duration))
                    }
                    Text(verbatim: record.model)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.saveCorrection()
            } label: {
                Label(String(localized: "geminiVoice.saveCorrection", defaultValue: "Save Correction"), systemImage: "checkmark.circle")
            }
        }
    }

    private func transcriptSection(_ record: GeminiVoiceSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "geminiVoice.transcript", defaultValue: "Transcript"))
                .font(.headline)
            ScrollView {
                Text(verbatim: record.transcript.isEmpty ? record.status.localizedTitle : record.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "geminiVoice.correction", defaultValue: "Correction"))
                .font(.headline)
            TextEditor(text: $viewModel.correctionDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(String(localized: "geminiVoice.correction", defaultValue: "Correction"))
        }
    }
}

private struct GeminiVoiceSessionRow: View {
    let record: GeminiVoiceSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.createdAt.formatted(date: .numeric, time: .shortened))
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack {
                Text(verbatim: record.status.localizedTitle)
                if let duration = record.durationSeconds {
                    Text(verbatim: String(format: "%.1fs", duration))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !record.transcript.isEmpty {
                Text(verbatim: record.transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
