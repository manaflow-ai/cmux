import AppKit
import Carbon.HIToolbox
import CmuxNextDictation
import CmuxNextSettings

/// The composer's mic when `agentPane.dictationSource` names an app the person already dictates
/// with (design/composer-dictation.md): the mic sends that app's shortcut instead of starting
/// cmux's own dictation, and macOS Dictation starts in the composer. The page never names the keys:
/// it says only `dictation.handoff`, and the host sends the chord of the source the settings name,
/// so page script cannot type into another app.
///
/// Leo, 2026-11-07: "you can optionally have it be like, oh, you use Claude's thing, or ChatGPT's
/// thing ... Or, like, maybe you can map the button to that thing, perhaps?"
struct AgentPaneDictationHandoff {
    /// One app the mic can hand off to.
    struct App: Equatable {
        let source: AgentPaneDictationSource
        /// The app's bundle ids, the current one first (ChatGPT's unified app, then ChatGPT Classic).
        let bundleIds: [String]
        /// The chord the app listens for by default; `agentPane.dictationShortcut` replaces it.
        let shortcut: String
    }

    /// The apps, in the order the mic's menu lists them. Bundle ids and default shortcuts are the
    /// research in design/composer-dictation.md.
    static let apps: [App] = [
        App(source: .chatgpt, bundleIds: ["com.openai.codex", "com.openai.chat"], shortcut: "opt+space"),
        App(source: .claude, bundleIds: ["com.anthropic.claudefordesktop"], shortcut: "opt+space"),
        App(source: .gemini, bundleIds: ["com.google.GeminiMacOS"], shortcut: "opt+space"),
        App(source: .wisprFlow, bundleIds: ["com.electron.wispr-flow", "com.wispr.flowapp"], shortcut: "ctrl+opt+space"),
        App(source: .superwhisper, bundleIds: ["com.superduper.superwhisper", "com.superduper.superwhisper-setapp"], shortcut: "opt+space"),
    ]

    static func app(_ source: AgentPaneDictationSource) -> App? { apps.first { $0.source == source } }

    /// Where an app is installed (tests pass their own).
    var installedURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    /// Whether this app may post key events (Accessibility), asking once when it may not.
    var mayPost: () -> Bool = {
        if CGPreflightPostEventAccess() { return true }
        _ = CGRequestPostEventAccess()
        return false
    }
    /// Posts one key press with its modifiers held.
    var post: (_ keyCode: CGKeyCode, _ flags: CGEventFlags) -> Bool = { keyCode, flags in
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
    /// Ends cmux's own dictation wherever it runs (another pane's, Home's or a terminal's), keeping
    /// its words: the microphone goes to the app the mic hands off to, never to two listeners at once.
    var stopOwnDictation: () -> Void = {
        DictationMicrophone.shared.stopListening()
        DictationMicrophoneClaims.shared.yield()
    }
    /// macOS Dictation, in the composer that has the keyboard.
    var systemDictation: () -> Void = { _ = NSApp.tryToPerform(AgentPaneDictationKey.action, with: nil) }

    /// The bundle id of `app` this Mac has, or nil.
    func installed(_ app: App) -> String? { app.bundleIds.first { installedURL($0) != nil } }

    /// `dictation.sources`: each app source this Mac has, for the mic's menu. Apps the Mac does not
    /// have are left out, so the page learns nothing about them. Whether one runs is not read: cmux
    /// never scans processes (plans/cmux-next/pty-holder.md).
    func sources() -> [[String: Any]] {
        Self.apps.compactMap { app in
            installed(app).map { ["id": app.source.rawValue, "bundleId": $0] }
        }
    }

    /// Why a hand-off did not happen.
    enum Failure: Error, Equatable {
        /// The source is cmux's own: the caller starts cmux's dictation.
        case ownDictation
        /// Automation ran it (`cmux action run`, an agent): only a person's own press types into
        /// another app.
        case notPersons
        case notInstalled
        case noAccessibility
        case badShortcut
        case postFailed
    }

    /// Sends the mic press to `setting`'s source: nil when it went, else why not.
    func handOff(_ setting: AgentPaneComposerSetting) -> Failure? {
        switch setting.dictationSource {
        case .cmux: return .ownDictation
        case .macos:
            stopOwnDictation()
            systemDictation()
            return nil
        default: break
        }
        guard let app = Self.app(setting.dictationSource) else { return .ownDictation }
        guard installed(app) != nil else { return .notInstalled }
        stopOwnDictation()
        let text = setting.dictationShortcut.isEmpty ? app.shortcut : setting.dictationShortcut
        guard let chord = AgentPaneDictationShortcut(text), let keyCode = Self.keyCode(chord.key) else { return .badShortcut }
        guard mayPost() else { return .noAccessibility }
        return post(keyCode, Self.flags(chord.modifiers)) ? nil : .postFailed
    }

    static func flags(_ modifiers: AgentPaneDictationShortcut.Modifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    /// The virtual key of a key name ``AgentPaneDictationShortcut`` accepts (ANSI positions).
    static func keyCode(_ key: String) -> CGKeyCode? {
        let named: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
            "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13,
            "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19,
        ]
        return named[key].map { CGKeyCode($0) }
    }

    /// The page's reply to `dictation.handoff`: success, or the failure's code (the page words it).
    func reply(_ setting: AgentPaneComposerSetting) -> [String: Any] {
        guard let failure = handOff(setting) else { return AgentPaneReply.success() }
        let code = Self.code(failure)
        return AgentPaneReply.failure(code: code, message: code)
    }

    /// The code the page words a failure by (dictationSources.ts `handoffFailure`).
    static func code(_ failure: Failure) -> String {
        switch failure {
        case .ownDictation: "dictation.own"
        case .notPersons: "dictation.person_only"
        case .notInstalled: "dictation.app_not_installed"
        case .noAccessibility: "dictation.accessibility"
        case .badShortcut: "dictation.bad_shortcut"
        case .postFailed: "dictation.post_failed"
        }
    }
}
