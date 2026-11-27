import Foundation

/// Classic cmux settings that cmux-next reads under another key. Next adopts the
/// classic `cmux.json` as is on first launch (`CmuxConfigFile.prepareDefaultURL`),
/// so without this a classic key next renamed is silently ignored and the
/// upgrade loses that setting (hq#1870 parity audit, cx-iy8b7).
///
/// Only renames with the same effect are listed. A key whose classic value next
/// cannot express, or that next spells differently in kind (theme names,
/// accent choices), stays where it is.
enum ClassicSettingRename {
    struct Entry: Sendable {
        let classic: [String]
        let next: [String]
        let transform: @Sendable (JSONValue) -> JSONValue?
    }

    static let identity: @Sendable (JSONValue) -> JSONValue? = { $0 }

    /// A value mapped by its classic spelling (a string or `true`/`false`).
    static func map(_ table: [String: JSONValue]) -> @Sendable (JSONValue) -> JSONValue? {
        { value in
            switch value {
            case .string(let text): table[text]
            case .bool(let flag): table[flag ? "true" : "false"]
            default: nil
            }
        }
    }

    static let entries: [Entry] = [
        Entry(classic: ["paneBorderColor"], next: ["layout", "paneBorderColor"], transform: identity),
        Entry(classic: ["activePaneBorderColor"], next: ["focusRing", "color"], transform: identity),
        Entry(classic: ["notifications", "paneFlashColor"], next: ["notifications", "attention", "color"], transform: identity),
        Entry(classic: ["notifications", "paneFlash"], next: ["notifications", "attention", "flash"], transform: identity),
        Entry(classic: ["notifications", "paneFlashOnTyping"], next: ["notifications", "attention", "flashOnTyping"], transform: identity),
        // Classic's ring off kept the flash; next's style "none" would drop both.
        Entry(classic: ["notifications", "unreadPaneRing"], next: ["notifications", "attention", "persist"],
              transform: map(["false": .bool(false)])),
        Entry(classic: ["app", "newWorkspacePlacement"], next: ["workspaces", "newPlacement"],
              transform: map(["top": .string("top"), "afterCurrent": .string("afterCurrent"), "end": .string("bottom")])),
        Entry(classic: ["app", "equalizeSplitsOnCreate"], next: ["layout", "splitSizing"],
              transform: map(["true": .string("even"), "false": .string("halve")])),
        Entry(classic: ["app", "minimalMode"], next: ["window", "titlebar"],
              transform: map(["true": .string("minimal"), "false": .string("standard")])),
        Entry(classic: ["app", "focusHistoryIncludesPanesAndTabs"], next: ["navigation", "history", "scope"],
              transform: map(["true": .string("everything"), "false": .string("workspaces")])),
        Entry(classic: ["diffViewer", "defaultLayout"], next: ["diff", "layout"], transform: identity),
        Entry(classic: ["browser", "showSearchSuggestions"], next: ["browser", "omnibar", "remoteSuggestions"], transform: identity),
        // Engines next doesn't offer stay unmapped (the descriptor refuses them), and so does
        // "custom": without its template next would search with Google.
        Entry(classic: ["browser", "defaultSearchEngine"], next: ["browser", "searchEngine"],
              transform: { $0 == .string("custom") ? nil : $0 }),
        Entry(classic: ["browser", "discardHiddenWebViews"], next: ["browser", "hibernation"],
              transform: map(["false": .string("off")])),
        Entry(classic: ["notifications", "suppressWhenAppFocused"], next: ["notifications", "desktop"],
              transform: map(["true": .string("whenInactive")])),
        Entry(classic: ["sidebar", "showPorts"], next: ["sidebar", "workspaceRow", "ports"], transform: identity),
        Entry(classic: ["sidebar", "showLog"], next: ["sidebar", "workspaceRow", "log"], transform: identity),
        Entry(classic: ["sidebar", "showProgress"], next: ["sidebar", "workspaceRow", "progress"], transform: identity),
        Entry(classic: ["sidebar", "showPullRequests"], next: ["sidebar", "workspaceRow", "pullRequest"], transform: identity),
        // "Show Branch + Directory" is two rows in next.
        Entry(classic: ["sidebar", "showBranchDirectory"], next: ["sidebar", "workspaceRow", "directory"], transform: identity),
        Entry(classic: ["sidebar", "showBranchDirectory"], next: ["sidebar", "workspaceRow", "branch"], transform: identity),
        Entry(classic: ["sidebar", "showAgentActivity"], next: ["sidebar", "workspaceRow", "working"], transform: identity),
        Entry(classic: ["sidebar", "showNotificationMessage"], next: ["sidebar", "workspaceRow", "notification"], transform: identity),
        // Next moves a workspace only for a notification; agentActivity's extra moves are not ported.
        Entry(classic: ["app", "reorderOnNotification"], next: ["notifications", "attention", "moveToTop"],
              transform: map(["true": .bool(true), "false": .bool(false), "off": .bool(false),
                              "notifications": .bool(true), "agentActivity": .bool(true)])),
    ]
}

extension SettingsController {
    /// Moves each classic key in `ClassicSettingRename.entries` to its next key
    /// in one atomic write, once at launch. A value next's descriptor accepts is
    /// written and the classic key dropped; a next key already set wins and the
    /// classic key is dropped; a classic value next can't express stays.
    /// Returns whether it wrote.
    @discardableResult
    public func migrateClassicSettings() async throws -> Bool {
        var edits: [(path: [String], value: JSONValue?)] = []
        for entry in ClassicSettingRename.entries {
            guard let old = try await file.value(at: entry.classic) else { continue }
            if try await file.value(at: entry.next) == nil {
                guard let value = entry.transform(old),
                      SettingsSchema.all.first(where: { $0.path == entry.next })?.accepts(value) == true else { continue }
                edits.append((entry.next, value))
            }
            edits.append((entry.classic, nil))
        }
        guard !edits.isEmpty else { return false }
        try await file.apply(edits)
        await reloadAfterWrite()
        return true
    }
}
