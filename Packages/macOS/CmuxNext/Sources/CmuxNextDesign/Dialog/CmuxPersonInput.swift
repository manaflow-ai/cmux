public import AppKit
import Darwin
import os
import Security

/// Tells the person's own key or click from automation's (cx-zk9t), for the
/// buttons only the person may press (`CmuxDialogConfirmKind`).
///
/// An event is the person's when the app did not post it itself
/// (`isAppSynthetic`, set by the app from `SyntheticInput`) and its CGEvent
/// source process is 0 (the HID system), this app, or an Apple-signed system
/// remote-input process from `remoteInputIdentifiers`, checked by code
/// signature (anchor apple and the exact identifier), never by name: Screen
/// Sharing, Universal Control and the accessibility input servers. Every other
/// posting process is refused.
///
/// This is not a security boundary against a process with the Accessibility
/// permission: such a process can already act as the user. It stops our own
/// automation and casual event posting. Residual: an agent that drives a VNC
/// session through screensharingd posts events the app accepts.
@MainActor
public struct CmuxPersonInput {
    /// The one instance the dialog views read; the app sets `isAppSynthetic` at launch.
    public static var shared = CmuxPersonInput()
    /// True for input the app posted into itself (debug socket, tests).
    public var isAppSynthetic: @MainActor (NSEvent) -> Bool

    /// The code signing identifiers (all anchor apple) whose posted events count as the
    /// person's: Screen Sharing (daemon, agent, VNC server), Universal Control, and the
    /// accessibility input servers (Voice Control and Switch Control, Dwell Control, VoiceOver).
    nonisolated public static let remoteInputIdentifiers = [
        "com.apple.screensharing.daemon", "com.apple.screensharing.agent", "com.apple.AppleVNCServer",
        "com.apple.universalcontrol", "com.apple.AccessibilityUIServer", "com.apple.DwellControl", "com.apple.VoiceOver",
    ]

    public init(isAppSynthetic: @escaping @MainActor (NSEvent) -> Bool = { _ in false }) {
        self.isAppSynthetic = isAppSynthetic
    }

    /// Whether `event` is the person's own key or click. No event is never the person.
    public func isPerson(_ event: NSEvent?) -> Bool {
        let (person, reason, source) = decide(event)
        record(person: person, reason: reason, source: source)
        return person
    }

    /// Whether a button action now comes from the person's own click or key in `window`: the
    /// event in dispatch is the person's, a click or key, in that window, and current (an
    /// action an accessibility press starts sees the last, stale, event instead).
    public func isPersonAction(_ event: NSEvent?, in window: NSWindow?) -> Bool {
        guard let event, [.leftMouseUp, .leftMouseDown, .keyDown].contains(event.type),
              event.window == nil || event.window === window,
              abs(ProcessInfo.processInfo.systemUptime - event.timestamp) < 2 else {
            record(person: false, reason: "stale-or-foreign-event", source: nil)
            return false
        }
        return isPerson(event)
    }

    /// Whether an accessibility press of a user-only button is accepted: only while an
    /// assistive technology that presses through accessibility runs (VoiceOver, Switch
    /// Control). Residual: an agent could press while one runs. Voice Control has no
    /// public flag, so its presses are refused.
    public func acceptsAccessibilityPress() -> Bool {
        let workspace = NSWorkspace.shared
        let accepted = workspace.isVoiceOverEnabled || workspace.isSwitchControlEnabled
        record(person: accepted, reason: accepted ? "ax-press-assistive" : "ax-press", source: nil)
        return accepted
    }

    private func decide(_ event: NSEvent?) -> (Bool, String, Int64?) {
        guard let event else { return (false, "no-event", nil) }
        if isAppSynthetic(event) { return (false, "app-synthetic", nil) }
        guard let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) else { return (true, "no-cgevent", nil) }
        if source == 0 { return (true, "hid", source) }
        if source == Int64(getpid()) { return (true, "this-app", source) }
        if Self.isAppleRemoteInput(pid_t(source)) { return (true, "apple-remote-input", source) }
        return (false, "posted-by-other-process", source)
    }

    /// Whether `pid` runs Apple-signed code with one of `remoteInputIdentifiers`.
    nonisolated static func isAppleRemoteInput(_ pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return remoteInputIdentifiers.contains { identifier in
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString("anchor apple and identifier \"\(identifier)\"" as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    }

    // MARK: Diagnostics

    /// One user-only press decision (DEBUG builds keep the last ones for `debug.dialog`).
    public struct Check: Sendable {
        public var person: Bool
        public var reason: String
        public var sourcePID: Int64?
        public var at: Date
    }

    #if DEBUG
    /// The latest decisions, newest last (`debug.dialog` reports them as `person_checks`).
    public private(set) static var recentChecks: [Check] = []
    #endif

    private func record(person: Bool, reason: String, source: Int64?) {
        #if DEBUG
        Self.recentChecks.append(Check(person: person, reason: reason, sourcePID: source, at: Date()))
        if Self.recentChecks.count > 32 { Self.recentChecks.removeFirst(Self.recentChecks.count - 32) }
        Logger(subsystem: "com.cmuxterm.app.next", category: "dialog.person")
            .notice("user-only press: person=\(person, privacy: .public) reason=\(reason, privacy: .public) source_pid=\(source.map(String.init) ?? "-", privacy: .public)")
        #endif
    }
}
