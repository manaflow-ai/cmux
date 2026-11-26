/// `remoteDesktop.*` in cmux.json: the viewer's defaults for a new Screen Sharing session
/// (plans/cmux-next/remote-desktop.md section 16). Mac Screen seeds each session's toolbar picks
/// from them, and the session's cmux.rd offer carries them; a toolbar pick still wins for its session.
/// - `quality` (Auto by default): Auto, Sharp Text, Smooth Motion or Low Bandwidth.
/// - `maxFps` (`"auto"` by default, or 1 to 240): a cap on the frame rate the offer asks for.
/// - `maxBitrateMbps` (`"auto"` by default, or 0.5 to 80): the offer's bitrate cap.
/// - `sharpLinuxText` (off by default): the viewer's hello offers cap `video.sharp_text`, so a Linux
///   host whose encoder is OpenH264 codes the session in screen usage, not camera usage.
public nonisolated struct RemoteDesktopDefaults: Sendable, Equatable {
    public var quality = RemoteDesktopDefaults.qualityDefault
    /// nil: Auto (the quality's own rate, this Mac's display refresh).
    public var maxFps: Int?
    /// nil: Auto (the host's own cap).
    public var maxBitrateMbps: Double?
    /// Settings > Customize "Sharper Text from Linux Machines": sharper text over a faster encode.
    public var sharpLinuxText = RemoteDesktopDefaults.sharpLinuxTextDefault

    public init() {}

    /// The bitrate cap in kbit/s, as the offer's `a=cmux-rd-max-kbps` takes it; nil for Auto.
    public var maxKbps: Int? { maxBitrateMbps.map { Int(($0 * 1000).rounded()) } }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["remoteDesktop"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.choice("quality", RemoteDesktopQuality.self) { settings.quality = value }
        settings.maxFps = Self.autoOrNumber(&reader, "maxFps", range: Self.maxFpsRange).map { Int($0.rounded()) }
        settings.maxBitrateMbps = Self.autoOrNumber(&reader, "maxBitrateMbps", range: Self.maxBitrateMbpsRange)
        if let value = reader.bool("sharpLinuxText") { settings.sharpLinuxText = value }
        diagnostics = reader.diagnostics
        return settings
    }

    /// A choice-or-number field whose one choice is `"auto"`: nil for `"auto"` or an absent key, else the number.
    private static func autoOrNumber(_ reader: inout ConfigFieldReader, _ key: String, range: ClosedRange<Double>) -> Double? {
        guard let value = reader.members[key] else { return nil }
        if value.stringValue == "auto" { return nil }
        return reader.number(key, range: range)
    }
}
