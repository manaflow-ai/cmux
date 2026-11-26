/// The settings Meet Chief reads and writes (``ChiefOnboarding``): what Chief may do on this Mac, the density and
/// the text size.
///
/// The app conforms with its settings (each write is the person's own, as Settings makes it); tests pass a fake.
/// The properties are read inside observation, so an observable conformer wakes the card when a setting changes
/// elsewhere (Settings, `cmux settings set`, cmux-next.json).
@MainActor
public protocol ChiefOnboardingSettings: AnyObject {
    /// The permission mode in effect now (`chief.permissionMode`).
    var mode: ChiefPermissionMode { get }
    /// Whether an administrator (MDM or the team policy) sets the mode, so the person cannot change it here.
    var modeManaged: Bool { get }
    /// Writes `mode` as the person's pick.
    /// - Throws: The settings write's error (a managed key, a file that could not be written).
    func setMode(_ mode: ChiefPermissionMode) async throws

    /// The density in effect, nil when it is one Meet Chief does not offer (Ultra-compact, Spacious, a custom one).
    var density: ChiefOnboardingDensity? { get }
    /// Writes `density` as the person's pick.
    /// - Throws: The settings write's error.
    func setDensity(_ density: ChiefOnboardingDensity) async throws

    /// The interface text size in effect, in points (the density's own size while the setting is unset).
    var textSize: Double { get }
    /// The sizes the setting takes.
    var textSizeRange: ClosedRange<Double> { get }
    /// Writes `points` as the person's text size.
    /// - Throws: The settings write's error.
    func setTextSize(_ points: Double) async throws
}
