#if os(iOS)
import AVFoundation
import CmuxMobileDesign
import NaturalLanguage
import Observation
import SwiftUI
import UIKit

// MARK: - Copy rows (the Mac's AgentChatCopyActionCatalog)

/// One of the chat's Copy rows. Each copies one named value, as the Mac's palette rows do.
public enum AgentChatCopy: String, CaseIterable, Identifiable, Sendable {
    case agentName
    case sessionID
    case harnessSessionID
    case conversation
    case details
    case workingDirectory
    case host

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agentName: String(localized: "Copy Agent Name")
        case .sessionID: String(localized: "Copy Session ID")
        case .harnessSessionID: String(localized: "Copy Harness Session ID")
        case .conversation: String(localized: "Copy Conversation as Markdown")
        case .details: String(localized: "Copy Session Details")
        case .workingDirectory: String(localized: "Copy Working Directory")
        case .host: String(localized: "Copy Chat Host")
        }
    }

    public var systemImage: String {
        switch self {
        case .agentName: "person.text.rectangle"
        case .sessionID: "doc.on.doc"
        case .harnessSessionID: "number"
        case .conversation: "text.quote"
        case .details: "doc.text.magnifyingglass"
        case .workingDirectory: "folder"
        case .host: "network"
        }
    }

    /// What the row copies; throws the reason when the chat has none (the Mac's refusals).
    @MainActor
    public func text(for store: AgentChatStore) async throws -> String {
        switch self {
        case .conversation:
            let text = Self.conversationMarkdown(store.turns)
            guard !text.isEmpty else { throw AgentFeatureUnavailable(String(localized: "This chat has no conversation to copy yet.")) }
            return text
        case .agentName, .sessionID, .harnessSessionID, .details, .workingDirectory, .host:
            // The chat's acpmux id (a workspace tab's chat is listed under its tab's id).
            let details = try await store.source.sessionDetails()
            let value: String? = switch self {
            case .agentName: details.name
            case .sessionID: details.sessionID
            case .harnessSessionID: details.harnessSessionID
            case .workingDirectory: details.cwd
            case .host: details.host
            default: details.detailsText
            }
            guard let value, !value.isEmpty else { throw AgentFeatureUnavailable(missing) }
            return value
        }
    }

    private var missing: String {
        switch self {
        case .agentName: String(localized: "This chat has no agent name yet.")
        case .harnessSessionID: String(localized: "This chat has no harness session ID yet.")
        case .workingDirectory: String(localized: "This chat has no working directory yet.")
        case .host: String(localized: "This chat has no host name yet.")
        default: String(localized: "This chat has no session details to copy yet.")
        }
    }

    /// The Mac's Copy Conversation as Markdown (webviews header/copyRow.ts): each prompt as
    /// "**User:**", each answer as "**Assistant:**", and each tool call as a short title line,
    /// never its input or output.
    public static func conversationMarkdown(_ turns: [AgentTurn]) -> String {
        var blocks: [String] = []
        for turn in turns {
            let prompt = turn.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty || !turn.attachments.isEmpty {
                blocks.append("**User:**\n" + (prompt.isEmpty ? "(attachment)" : prompt))
            }
            for item in turn.items {
                switch item {
                case .message(_, let markdown):
                    let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { blocks.append("**Assistant:**\n" + text) }
                case .tool(let call):
                    let title = call.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    guard !title.isEmpty else { continue }
                    blocks.append("- Tool: " + (title.count > 160 ? String(title.prefix(157)) + "…" : title))
                default:
                    continue
                }
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// The Copy rows' sheet (a list, one row per value, as the Mac's palette rows).
struct ChatCopyChoicesSheet: View {
    let store: AgentChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var copying: AgentChatCopy?
    @State private var copied: AgentChatCopy?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AgentChatCopy.allCases) { row in
                        Button {
                            copy(row)
                        } label: {
                            HStack {
                                Label(row.title, systemImage: row.systemImage)
                                Spacer()
                                if copying == row {
                                    ProgressView()
                                } else if copied == row {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Copied")
                                }
                            }
                        }
                        .tint(.primary)
                        .disabled(copying != nil)
                        .accessibilityIdentifier("chat.copy.\(row.rawValue)")
                    }
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(Color.cmuxMobileDanger)
                    }
                }
            }
            .navigationTitle("Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .presentationDetents([.medium, .large])
    }

    private func copy(_ row: AgentChatCopy) {
        copying = row
        failure = nil
        Task { @MainActor in
            do {
                UIPasteboard.general.string = try await row.text(for: store)
                copied = row
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            copying = nil
        }
    }
}

// MARK: - Text and Width (the Mac's Zoom In / Zoom Out / Actual Size and Text & Width)

/// One chat's text size and column, kept on this phone per chat.
public struct ChatDisplaySettings: Codable, Hashable, Sendable {
    /// Text size steps from the person's own size (0: Actual Size).
    public var zoomStep = 0
    /// The chat fills the screen (the phone's default); off, it stops at ``standardColumn``.
    public var fullWidth = true

    public init(zoomStep: Int = 0, fullWidth: Bool = true) {
        self.zoomStep = zoomStep
        self.fullWidth = fullWidth
    }

    /// The Mac chat column's standard width (webviews chatWidth.ts: 720 px).
    public static let standardColumn: CGFloat = 720

    /// The text sizes a chat zooms through, smallest first, with each one's body size.
    static let sizes: [(category: UIContentSizeCategory, body: CGFloat)] = [
        (.extraSmall, 14), (.small, 15), (.medium, 16), (.large, 17), (.extraLarge, 19), (.extraExtraLarge, 21),
        (.extraExtraExtraLarge, 23), (.accessibilityMedium, 28), (.accessibilityLarge, 33), (.accessibilityExtraLarge, 40),
    ]

    static func index(of category: UIContentSizeCategory) -> Int {
        if let exact = sizes.firstIndex(where: { $0.category == category }) { return exact }
        // Sizes past the list (the two largest accessibility sizes) count as its last.
        return category.rawValue.contains("Accessibility") ? sizes.count - 1 : 3
    }

    /// The size the chat draws at over the person's `system` size; nil: the system's own.
    public func category(system: UIContentSizeCategory) -> UIContentSizeCategory? {
        guard zoomStep != 0 else { return nil }
        let index = min(max(Self.index(of: system) + zoomStep, 0), Self.sizes.count - 1)
        return Self.sizes[index].category
    }

    /// The text size as a share of Actual Size, in percent (the Mac's zoom indicator).
    public func percent(system: UIContentSizeCategory) -> Int {
        let base = Self.index(of: system)
        let index = min(max(base + zoomStep, 0), Self.sizes.count - 1)
        return Int((Self.sizes[index].body / Self.sizes[base].body * 100).rounded())
    }

    public func canZoomIn(system: UIContentSizeCategory) -> Bool { Self.index(of: system) + zoomStep < Self.sizes.count - 1 }
    public func canZoomOut(system: UIContentSizeCategory) -> Bool { Self.index(of: system) + zoomStep > 0 }
}

/// Every chat's Text and Width, kept in this phone's defaults by Mac and chat (the newest
/// `limit`; an older chat goes back to the defaults).
@MainActor
@Observable
public final class ChatDisplayPreferences {
    public static let shared = ChatDisplayPreferences()
    static let defaultsKey = "cmux.chat.display.v1"
    static let limit = 300

    private struct Stored: Codable {
        var order: [String] = []
        var settings: [String: ChatDisplaySettings] = [:]
    }

    private var stored: Stored
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    static func key(_ summary: AgentSessionSummary) -> String { "\(summary.macID)|\(summary.id)" }

    public func settings(for summary: AgentSessionSummary) -> ChatDisplaySettings {
        stored.settings[Self.key(summary)] ?? ChatDisplaySettings()
    }

    public func update(_ summary: AgentSessionSummary, _ change: (inout ChatDisplaySettings) -> Void) {
        let key = Self.key(summary)
        var value = settings(for: summary)
        change(&value)
        stored.order.removeAll { $0 == key }
        if value == ChatDisplaySettings() {
            stored.settings[key] = nil
        } else {
            stored.settings[key] = value
            stored.order.append(key)
        }
        while stored.order.count > Self.limit {
            stored.settings[stored.order.removeFirst()] = nil
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Text and Width: the chat's text size (Zoom Out, Actual Size, Zoom In) and its width.
struct ChatDisplaySettingsSheet: View {
    let summary: AgentSessionSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sizeCategory) private var sizeCategory
    private let preferences = ChatDisplayPreferences.shared

    var body: some View {
        let settings = preferences.settings(for: summary)
        let system = UIContentSizeCategory(sizeCategory)
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Zoom Out", systemImage: "textformat.size.smaller") { zoom(-1) }
                            .labelStyle(.iconOnly)
                            .disabled(!settings.canZoomOut(system: system))
                            .accessibilityIdentifier("chat.display.zoomOut")
                        Spacer()
                        Text("\(settings.percent(system: system))%")
                            .font(.title3.monospacedDigit())
                            .contentTransition(.numericText())
                            .accessibilityLabel(Text("Text size \(settings.percent(system: system)) percent"))
                            .accessibilityIdentifier("chat.display.percent")
                        Spacer()
                        Button("Zoom In", systemImage: "textformat.size.larger") { zoom(1) }
                            .labelStyle(.iconOnly)
                            .disabled(!settings.canZoomIn(system: system))
                            .accessibilityIdentifier("chat.display.zoomIn")
                    }
                    .buttonStyle(.borderless)
                    .font(.title2)
                    Button("Actual Size") { preferences.update(summary) { $0.zoomStep = 0 } }
                        .disabled(settings.zoomStep == 0)
                        .accessibilityIdentifier("chat.display.actualSize")
                } header: {
                    Text("Text Size")
                } footer: {
                    Text("Only this chat changes. Other chats keep your text size.")
                }
                Section {
                    Picker("Width", selection: Binding(get: { settings.fullWidth }, set: { full in
                        preferences.update(summary) { $0.fullWidth = full }
                    })) {
                        Text("Full Width").tag(true)
                        Text("Standard").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("chat.display.width")
                } header: {
                    Text("Width")
                } footer: {
                    Text("Standard stops the chat at 720 points, as on the Mac. It changes the chat in landscape and on wider screens.")
                }
            }
            .navigationTitle("Text and Width")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { preferences.update(summary) { $0 = ChatDisplaySettings() } }
                        .disabled(settings == ChatDisplaySettings())
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // The chat under the sheet shows each change as it is made.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func zoom(_ step: Int) {
        preferences.update(summary) { $0.zoomStep += step }
    }
}

// MARK: - Previous/Next Turn and bookmarked prompts (AgentTranscriptActionCatalog)

/// The turn bar: Previous and Next Turn, or (Bookmarked) Previous and Next Bookmarked Prompt.
/// At either end the step does nothing, as on the Mac (no wrap-around).
@MainActor
@Observable
public final class ChatTurnNavigator {
    /// Which turns the bar steps through; switching it forgets the position (another list).
    public var bookmarkedOnly = false { didSet { if bookmarkedOnly != oldValue { position = nil } } }
    /// The turn the bar last moved to (its index among the turns it steps through).
    public private(set) var position: Int?
    public init(bookmarkedOnly: Bool = false) { self.bookmarkedOnly = bookmarkedOnly }

    /// The turn to go to from the one being read: `forward` the next one after it; back, the
    /// reading turn itself when its prompt is above the view, else the one before it.
    nonisolated static func target(count: Int, reading: (index: Int, aboveTop: Bool)?, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let reading else { return forward ? 0 : nil }
        if forward { return reading.index + 1 < count ? reading.index + 1 : nil }
        if reading.aboveTop { return reading.index }
        return reading.index > 0 ? reading.index - 1 : nil
    }

    func step(forward: Bool, store: AgentChatStore, surface: AgentChatSurface) {
        let turns = store.navigableTurns(bookmarkedOnly: bookmarkedOnly)
        let reading = surface.scroller?.readingTurn(among: turns.map(\.id))
        // The reader may have scrolled since the last step: the bar shows where they are.
        if let reading { position = reading.index }
        guard let index = Self.target(count: turns.count, reading: reading, forward: forward) else {
            UIAccessibility.post(notification: .announcement, argument: forward ? String(localized: "No later turn") : String(localized: "No earlier turn"))
            return
        }
        position = index
        surface.scroller?.revealFindBlock(AgentChatFind.promptKey(turns[index].id), position: 0,
                                          animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

/// The turn bar under the header (where Find in Chat's bar goes).
struct ChatTurnBar: View {
    let navigator: ChatTurnNavigator
    let store: AgentChatStore
    let surface: AgentChatSurface

    var body: some View {
        let turns = store.navigableTurns(bookmarkedOnly: navigator.bookmarkedOnly)
        HStack(spacing: 12) {
            Button {
                navigator.bookmarkedOnly.toggle()
            } label: {
                Image(systemName: navigator.bookmarkedOnly ? "bookmark.fill" : "bookmark")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Bookmarked prompts only")
            .accessibilityValue(navigator.bookmarkedOnly ? Text("On") : Text("Off"))
            .accessibilityIdentifier("chat.turns.bookmarked")
            Text(label(count: turns.count))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chat.turns.count")
            Button {
                navigator.step(forward: false, store: store, surface: surface)
            } label: {
                Image(systemName: "chevron.up").frame(width: 32, height: 32)
            }
            .disabled(turns.isEmpty)
            .accessibilityLabel(navigator.bookmarkedOnly ? "Previous Bookmarked Prompt" : "Previous Turn")
            .accessibilityIdentifier("chat.turns.previous")
            Button {
                navigator.step(forward: true, store: store, surface: surface)
            } label: {
                Image(systemName: "chevron.down").frame(width: 32, height: 32)
            }
            .disabled(turns.isEmpty)
            .accessibilityLabel(navigator.bookmarkedOnly ? "Next Bookmarked Prompt" : "Next Turn")
            .accessibilityIdentifier("chat.turns.next")
            Button("Done") { surface.turnNavigator = nil }
                .fontWeight(.semibold)
                .accessibilityIdentifier("chat.turns.done")
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
    }

    private func label(count: Int) -> String {
        if navigator.bookmarkedOnly && count == 0 { return String(localized: "No bookmarked prompts") }
        guard let position = navigator.position, position < count else {
            return navigator.bookmarkedOnly ? String(localized: "\(count) bookmarked") : String(localized: "\(count) turns")
        }
        return navigator.bookmarkedOnly ? String(localized: "Bookmark \(position + 1) of \(count)")
            : String(localized: "Turn \(position + 1) of \(count)")
    }
}

// MARK: - Bookmark, Pin and Read Aloud in the SwiftUI rows (accessibility text sizes)

/// The same rows as `ChatPolishMenus`, for the SwiftUI prompt bubble and answer row.
/// `prompt`: the prompt's text (a prompt's menu), nil for the answer's.
struct ChatPolishMenuButtons: View {
    let store: AgentChatStore
    let turnID: String
    let prompt: String?

    var body: some View {
        if let turn = store.turns.first(where: { $0.id == turnID }) {
            if prompt != nil {
                if store.canBookmark(turn) {
                    Button(store.isBookmarked(turn) ? "Remove Bookmark" : "Bookmark",
                           systemImage: store.isBookmarked(turn) ? "bookmark.slash" : "bookmark") { store.toggleBookmark(turn) }
                }
            } else if store.canPin(turn) {
                Button(store.isPinned(turn) ? "Unpin" : "Pin", systemImage: store.isPinned(turn) ? "pin.slash" : "pin") { store.togglePin(turn) }
            }
            let text = prompt ?? turn.answerMarkdown
            if !text.isEmpty {
                let id = ChatReadAloud.id(chat: store.summary.id, turn: turnID, prompt: prompt != nil)
                let reading = ChatReadAloud.shared.isReading(id)
                Button(reading ? "Stop Reading" : "Read Aloud", systemImage: reading ? "stop.circle" : "speaker.wave.2") {
                    ChatReadAloud.shared.toggle(id, markdown: text)
                }
            }
        }
    }
}

// MARK: - Read Aloud (the Mac's message row "Read aloud")

/// Reads one message aloud at a time with the system voice. Starting another stops the
/// first; the same message again stops it, as on the Mac.
@MainActor
@Observable
public final class ChatReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = ChatReadAloud()
    /// The message being read (its turn and kind), nil when quiet.
    public private(set) var reading: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        // The system plays it with its own audio session: the app's (a Chief call's) is untouched.
        synthesizer.usesApplicationAudioSession = false
    }

    public func isReading(_ id: String) -> Bool { reading == id }

    /// Reads `markdown` as message `id`, or stops when it is the one being read.
    public func toggle(_ id: String, markdown: String) {
        if reading == id {
            stop()
            return
        }
        stop()
        let text = Self.spokenText(markdown)
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.language(of: text))
        reading = id
        synthesizer.speak(utterance)
    }

    /// The id a message of `chat` reads under: the chat, the turn and which side.
    public static func id(chat: String, turn: String, prompt: Bool) -> String { "\(chat)|\(turn)|\(prompt ? "prompt" : "answer")" }

    /// The chat left the screen: what it was reading stops.
    public func stopIfReading(chat: String) {
        if reading?.hasPrefix(chat + "|") == true { stop() }
    }

    public func stop() {
        reading = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.reading = nil } }
    }

    /// The text spoken (webviews conversation/readAloud.ts `spokenText`): code blocks dropped,
    /// inline code, links and images keep their text, heading, quote and list markers and
    /// emphasis marks removed, whitespace collapsed.
    nonisolated static func spokenText(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            lines.append(line)
        }
        var text = lines.joined(separator: " ")
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"`([^`]*)`"#, "$1"),
            (#"(^|\s)(#{1,6}|>+|[-*+]|\d+[.)])\s+"#, "$1"),
            (#"(\*\*|__|~~|\*|_)"#, ""),
            (#"\s+"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The voice's language: the text's own when it is clear, else this phone's.
    nonisolated static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage, language != .undetermined,
           (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) > 0.6 {
            return language.rawValue
        }
        return AVSpeechSynthesisVoice.currentLanguageCode()
    }
}
#endif
