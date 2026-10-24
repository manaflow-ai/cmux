/// A view a typed key can go to whose own output the typing probe should follow (a terminal view): the probe
/// samples only that terminal's marks (``TypingLatencyProbe/Target``). The app reads it from the key window's first
/// responder when it opens a sample, and only while the probe is on.
@MainActor
public protocol TypingProbeTargeting: AnyObject {
    /// The terminal this view shows, as the probe scopes its marks.
    var typingProbeTarget: TypingLatencyProbe.Target { get }
}
