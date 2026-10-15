public import Foundation

/// What a page is doing that hidden-tab memory saving must not interrupt,
/// asked from the page itself right before its content is released.
///
/// WebKit panels learn media playback and form edits from their own message
/// handlers. Other engines report neither, so the panel runs this probe (a
/// port of cmux Next's hibernation field probe) in the page's main frame:
/// unmuted media playing, or form fields whose value differs from the
/// page's default. A page that does not answer within the deadline, or whose
/// answer cannot be read, counts as busy and keeps its content.
public struct BrowserPageBusyProbe: Equatable, Sendable {
    /// Unmuted `<audio>` or `<video>` is playing.
    public var playingMedia: Bool
    /// A form field differs from its default value.
    public var editedForm: Bool

    /// Creates a probe result.
    /// - Parameters:
    ///   - playingMedia: Unmuted media is playing.
    ///   - editedForm: A form field differs from its default.
    public init(playingMedia: Bool, editedForm: Bool) {
        self.playingMedia = playingMedia
        self.editedForm = editedForm
    }

    /// The result for a page that did not answer: keep it.
    public static let unanswered = BrowserPageBusyProbe(playingMedia: true, editedForm: true)

    /// The Memory Saver blocker names for this result, matching
    /// ``BrowserHiddenWebViewDiscardManager/blockers(for:now:urgency:)``.
    /// Under system memory pressure form edits do not block, as for WebKit.
    /// - Parameter underPressure: Whether the system reported memory pressure.
    /// - Returns: The blockers, empty when the page may be released.
    public func blockers(underPressure: Bool) -> [String] {
        var result: [String] = []
        if playingMedia { result.append("media_playback") }
        if editedForm && !underPressure { result.append("form_input") }
        return result
    }

    /// The probe script; it returns a JSON string `{"media": Bool, "form": Bool}`.
    public static let script = """
    (() => {
      const media = [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
      const form = [...document.querySelectorAll('input,textarea,select')].some(e => {
        if (e.disabled || e.type === 'hidden' || e.type === 'submit' || e.type === 'button') return false;
        if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
        if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
        return e.value !== e.defaultValue;
      });
      return JSON.stringify({media, form});
    })()
    """

    /// Reads the script's result.
    /// - Parameter value: What the page returned.
    /// - Returns: The result, or ``unanswered`` for anything unreadable.
    public static func parse(_ value: Any?) -> BrowserPageBusyProbe {
        guard let json = value as? String, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = object["media"] as? Bool, let form = object["form"] as? Bool else {
            return .unanswered
        }
        return BrowserPageBusyProbe(playingMedia: media, editedForm: form)
    }

    /// Runs the probe in a page, giving up after `deadline`.
    /// - Parameters:
    ///   - page: The page to ask.
    ///   - deadline: How long the page may take to answer.
    ///   - clock: The clock the deadline runs on.
    /// - Returns: The page's answer, or ``unanswered``.
    @MainActor
    public static func run(
        in page: any BrowserPage,
        deadline: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> BrowserPageBusyProbe {
        let answer = BrowserPageBusyProbeAnswer()
        let evaluation = Task { @MainActor in
            let value = try? await page.evaluateJavaScript(script, in: .page)
            answer.deliver(parse(value))
        }
        let timeout = Task { @MainActor in
            try? await clock.sleep(for: deadline)
            answer.deliver(.unanswered)
        }
        let result = await answer.value()
        evaluation.cancel()
        timeout.cancel()
        return result
    }
}
