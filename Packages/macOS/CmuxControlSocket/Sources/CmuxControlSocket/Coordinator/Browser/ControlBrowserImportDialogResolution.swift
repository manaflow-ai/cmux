/// The outcome of `browser.import.dialog`, the typed twin of the legacy
/// `TerminalController.v2BrowserImportDialog(params:)` body.
///
/// The witness owns the full `scope` / `destination_profile` validation (the
/// `BrowserImportScope` mapping plus the `BrowserProfileStore` lookup/create),
/// schedules the import dialog presentation on the main actor, and returns
/// ``opened`` carrying the resolved scope's raw value (or `nil` when no `scope`
/// was supplied). Each failure category maps to the exact legacy
/// `invalid_params` error the coordinator re-emits with the matching `param`
/// data.
public enum ControlBrowserImportDialogResolution: Sendable, Equatable {
    /// `scope` was present but empty/whitespace
    /// (`invalid_params` / "scope must be a non-empty string",
    /// data `{"param": "scope"}`).
    case scopeEmpty
    /// `scope` was present but not a recognized value
    /// (`invalid_params` / "scope is invalid", data `{"param": "scope"}`).
    case scopeInvalid
    /// `destination_profile` was present but empty/whitespace
    /// (`invalid_params` / "destination_profile must be a non-empty string",
    /// data `{"param": "destination_profile"}`).
    case destinationProfileEmpty
    /// `destination_profile` did not match a profile and creation was not
    /// requested (`invalid_params` /
    /// "destination_profile does not match a cmux browser profile",
    /// data `{"param": "destination_profile"}`).
    case destinationProfileNoMatch
    /// `destination_profile` creation was requested but failed
    /// (`invalid_params` / "destination_profile could not be created",
    /// data `{"param": "destination_profile"}`).
    case destinationProfileCreateFailed
    /// The dialog presentation was scheduled. `scopeRawValue` is the resolved
    /// `BrowserImportScope.rawValue` (or `nil` → JSON `null` for the `scope`
    /// payload key) when no `scope` was supplied.
    case opened(scopeRawValue: String?)
}
