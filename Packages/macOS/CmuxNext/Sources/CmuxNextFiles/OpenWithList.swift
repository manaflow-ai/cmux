import Foundation

/// The Open With submenu's rows in Finder's order: the default app first, then every other app
/// once, by name (case-insensitive, numbers in order), then Other….
///
/// ```swift
/// let list = OpenWithList(defaultApp: safari, apps: workspaceApps)
/// for app in list.apps { menu.addItem(row(app)) }   // Safari (default), Google Chrome, …
/// if list.offersOther { menu.addItem(otherItem) }
/// ```
public struct OpenWithList: Sendable, Equatable {
    /// The rows, default first.
    public let apps: [OpenWithApp]

    /// Other… (pick any app) is always offered, also when no app claims the type.
    public var offersOther: Bool { true }

    /// Orders `apps` with `defaultApp` first.
    ///
    /// - Parameters:
    ///   - defaultApp: the system's default app for the file, if any; it need not be in `apps`.
    ///   - apps: every app the system reports (`NSWorkspace.urlsForApplications(toOpen:)`),
    ///     duplicates allowed. Two copies of one app (same bundle id) make one row; the default's
    ///     copy, else the first, wins.
    public init(defaultApp: OpenWithApp?, apps: [OpenWithApp]) {
        var seen = Set<String>()
        var rows: [OpenWithApp] = []
        if var first = defaultApp {
            first.isDefault = true
            seen.insert(first.identity)
            rows.append(first)
        }
        var others: [OpenWithApp] = []
        for var app in apps where seen.insert(app.identity).inserted {
            app.isDefault = false
            others.append(app)
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.apps = rows + others
    }
}
