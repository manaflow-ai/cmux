public import CmuxNextDesign

/// Which Chief Home opens by default (#64, 2026-10-21): this Mac's Chief while this Mac's
/// optchat-chief runs, else the Hosted (cloud) Chief. Debug Settings' "Default Chief"
/// (``HomeTunables/chiefDefault``) can force either one.
public nonisolated enum HomeChiefDefault: String, Sendable, CaseIterable, TunableChoice {
    /// This Mac's Chief while its optchat-chief runs, else the Hosted Chief.
    case auto
    /// Always this Mac's Chief.
    case local
    /// Always the cloud Chief (the Hosted Chief, or the server's when the user switched to it).
    case hosted

    public var tunableTitle: String {
        switch self {
        case .auto: "Auto (this Mac's when running, else Hosted)"
        case .local: "This Mac's Chief"
        case .hosted: "Hosted (cloud) Chief"
        }
    }

    /// This Mac's Chief is the default: forced, or Auto while this Mac's optchat-chief runs.
    public func prefersLocal(localRunning: Bool) -> Bool {
        switch self {
        case .auto: localRunning
        case .local: true
        case .hosted: false
        }
    }
}
