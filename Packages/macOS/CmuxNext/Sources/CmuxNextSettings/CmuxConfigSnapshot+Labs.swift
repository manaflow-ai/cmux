import Foundation
public import Observation

/// Labs (hq#1980): new looks and behaviors ship behind a flag a person turns on, not in the
/// defaults. The flags are rows of schemas/settings/source/labs.json (``LabsFlag``, generated);
/// `labs.<name>` in cmux.json turns one on or off, and with nothing there its ``LabsCohort``
/// decides. Swift reads a flag with ``CmuxConfigSnapshot/lab(_:teamBuild:)``; pages read
/// `data-labs` on `<html>` (webviews/src/experiments/labs.ts). How to add one:
/// skills/cmux-architecture/references/labs-flags.md.
public nonisolated enum LabsCohort: String, Sendable {
    /// Off until a person turns it on.
    case off
    /// On in nightly and dev builds (the team), off in release and RC.
    case nightlyNext = "nightly-next"
    /// Promoted: on for everyone.
    case `default`

    public func isOn(teamBuild: Bool) -> Bool {
        switch self {
        case .off: false
        case .nightlyNext: teamBuild
        case .default: true
        }
    }
}

extension LabsFlag {
    /// `["labs", "<name>"]`.
    public var path: [String] { ["labs", rawValue] }

    /// Whether this app is a nightly or dev build, from its bundle identifier.
    public static let teamBuild = isTeamBuild(bundleID: Bundle.main.bundleIdentifier)

    /// `com.cmuxterm.app.nightly…` and the other descendants (debug, staging, tags) are team
    /// builds; `com.cmuxterm.app` (release), `.rc` and other apps are not.
    public static func isTeamBuild(bundleID: String?) -> Bool {
        let base = "com.cmuxterm.app."
        guard let id = bundleID, id.hasPrefix(base) else { return false }
        return id.dropFirst(base.count).split(separator: ".").first != "rc"
    }
}

extension CmuxConfigSnapshot {
    /// Whether `flag` is on: cmux.json's value, else its cohort for this build.
    public func lab(_ flag: LabsFlag, teamBuild: Bool = LabsFlag.teamBuild) -> Bool {
        labs[flag] ?? flag.cohort.isOn(teamBuild: teamBuild)
    }

    /// The names of the flags that are on, in registry order (`data-labs` for pages).
    public func labsOn(teamBuild: Bool = LabsFlag.teamBuild) -> [String] {
        LabsFlag.allCases.filter { lab($0, teamBuild: teamBuild) }.map(\.rawValue)
    }

    /// `labs.previewFeatures`: the agent pane's unfinished surfaces and Click by Hint.
    public var previewFeatures: Bool { lab(.previewFeatures) }

    /// `labs.classicHome`: Home as the classic top page (cx-ebm.59.5); read once at launch.
    public var classicHome: Bool { lab(.classicHome) }

    /// Each `labs.<name>` the file sets; a value that is not a bool is unset plus a diagnostic.
    static func parseLabs(_ root: JSONValue) -> ([LabsFlag: Bool], [SettingsDiagnostic]) {
        var values: [LabsFlag: Bool] = [:]
        var diagnostics: [SettingsDiagnostic] = []
        for flag in LabsFlag.allCases {
            guard let value = root.value(at: flag.path) else { continue }
            guard let on = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: flag.key, message: "expected true or false"))
                continue
            }
            values[flag] = on
        }
        return (values, diagnostics)
    }
}

/// The Labs flags on in the running app, for layers that have no ``SettingsController`` (every
/// page's `data-labs`, CmuxNextPages). The controller updates it with each loaded snapshot.
@MainActor
@Observable
public final class LabsState {
    public static let shared = LabsState()
    /// Their names, in registry order.
    public private(set) var on: [String] = []

    func update(_ snapshot: CmuxConfigSnapshot) {
        let names = snapshot.labsOn()
        if names != on { on = names }
    }
}

extension CmuxConfigSnapshot {
    /// Stores one setting's parsed value and keeps its diagnostic.
    mutating func take<Value>(_ parsed: (Value, SettingsDiagnostic?), _ keyPath: WritableKeyPath<Self, Value>) {
        self[keyPath: keyPath] = parsed.0
        if let diagnostic = parsed.1 { diagnostics.append(diagnostic) }
    }

    /// Stores one setting's parsed value and keeps its diagnostics.
    mutating func take<Value>(_ parsed: (Value, [SettingsDiagnostic]), _ keyPath: WritableKeyPath<Self, Value>) {
        self[keyPath: keyPath] = parsed.0
        diagnostics += parsed.1
    }
}
