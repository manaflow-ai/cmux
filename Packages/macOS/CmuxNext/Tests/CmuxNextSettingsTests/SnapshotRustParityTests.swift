import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Settings step B, snapshot area: `CmuxConfigSnapshot.parse` reads its plain true/false and choice keys
/// and the retired keys through Rust (`snapshot.read`, cmux-tui/crates/cmux-config/src/app_ops/snapshot.rs)
/// instead of the one-key Swift `XxxSetting.parse(root)` functions it deleted. The oracle below is that
/// deleted Swift; every key must give the same value and the same diagnostic on every input.
@Suite struct SnapshotRustParityTests {
    /// One key the snapshot now takes from Rust: its path, how the deleted Swift read it, and the field.
    struct Row: CustomStringConvertible, Sendable {
        let path: [String]
        let oracle: @Sendable (JSONValue) -> (JSONValue, SettingsDiagnostic?)
        let field: @Sendable (CmuxConfigSnapshot) -> JSONValue
        let samples: [JSONValue]
        var key: String { path.joined(separator: ".") }
        var description: String { key }
    }

    static func toggle(_ path: [String], _ fallback: Bool, _ field: @escaping @Sendable (CmuxConfigSnapshot) -> Bool) -> Row {
        Row(path: path, oracle: { root in
            let (on, diagnostic) = Oracle.toggle(root, path: path, fallback: fallback)
            return (.bool(on), diagnostic)
        }, field: { .bool(field($0)) }, samples: [.bool(true), .bool(false)])
    }

    static func choice<Choice: CaseIterable & RawRepresentable & Sendable>(
        _ path: [String], _ fallback: Choice, unquoted: Bool = false, _ field: @escaping @Sendable (CmuxConfigSnapshot) -> Choice
    ) -> Row where Choice.RawValue == String {
        Row(path: path, oracle: { root in
            let (choice, diagnostic) = Oracle.choice(root, path: path, fallback: fallback, unquoted: unquoted)
            return (.string(choice.rawValue), diagnostic)
        }, field: { .string(field($0).rawValue) }, samples: Choice.allCases.map { .string($0.rawValue) })
    }

    static let rows: [Row] = [
        toggle(BookmarksBarSetting.configPath, BookmarksBarSetting.fallback) { $0.browserShowBookmarksBar },
        toggle(BrowserVimKeysSetting.configPath, BrowserVimKeysSetting.fallback) { $0.browserVimKeys },
        toggle(BrowserLoadingBarSetting.configPath, BrowserLoadingBarSetting.fallback) { $0.browserShowLoadingBar },
        toggle(BrowserImportSetting.configPath, BrowserImportSetting.fallback) { $0.browserImportEnabled },
        toggle(BrowserCookieBannerSetting.configPath, BrowserCookieBannerSetting.fallback) { $0.browserImportCookieBanner },
        toggle(BrowserCookieSyncSetting.configPath, BrowserCookieSyncSetting.fallback) { $0.browserImportCookieSync },
        choice(HomeChiefBubbleStyleSetting.configPath, HomeChiefBubbleStyleSetting.fallback, unquoted: true) {
            HomeChiefBubbleStyle(rawValue: $0.homeChiefBubbleStyle) ?? HomeChiefBubbleStyleSetting.fallback
        },
        toggle(BuiltInAdBlockerSetting.configPath, BuiltInAdBlockerSetting.fallback) { $0.browserBuiltInAdBlocker },
        toggle(AgentCursorSetting.configPath, AgentCursorSetting.fallback) { $0.browserShowAgentCursor },
        toggle(CmuxConfigSnapshot.previewFeaturesPath, CmuxConfigSnapshot.previewFeaturesDefault) { $0.previewFeatures },
        toggle(CmuxConfigSnapshot.appStorePath, CmuxConfigSnapshot.appStoreDefault) { $0.appStore },
        toggle(CmuxConfigSnapshot.liveTreePath, CmuxConfigSnapshot.liveTreeDefault) { $0.liveTree },
        toggle(CmuxConfigSnapshot.voiceRoomPath, CmuxConfigSnapshot.voiceRoomDefault) { $0.voiceRoom },
        toggle(CmuxConfigSnapshot.machineJoinPath, CmuxConfigSnapshot.machineJoinDefault) { $0.machineJoin },
        toggle(CmuxConfigSnapshot.liveCodePath, CmuxConfigSnapshot.liveCodeDefault) { $0.liveCode },
        toggle(CmuxConfigSnapshot.pauseAgentMachinesPath, CmuxConfigSnapshot.pauseAgentMachinesDefault) { $0.pauseAgentMachines },
        toggle(CmuxConfigSnapshot.customizeFromTheAppPath, CmuxConfigSnapshot.customizeFromTheAppDefault) { $0.customizeFromTheApp },
        toggle(CmuxConfigSnapshot.customizeDoctorNoticePath, CmuxConfigSnapshot.customizeDoctorNoticeDefault) { $0.customizeDoctorNotice },
        toggle(CmuxConfigSnapshot.agentCustomizationPath, CmuxConfigSnapshot.agentCustomizationDefault) { $0.agentCustomization },
        toggle(CmuxConfigSnapshot.teamComputePath, CmuxConfigSnapshot.teamComputeDefault) { $0.teamCompute },
        toggle(CmuxConfigSnapshot.commentThreadsPath, CmuxConfigSnapshot.commentThreadsDefault) { $0.commentThreads },
        toggle(CmuxConfigSnapshot.hostsSidebarPath, CmuxConfigSnapshot.hostsSidebarDefault) { $0.hostsSidebar },
        choice(TerminalTermSetting.configPath, TerminalTermSetting.fallback) { $0.terminalTerm },
        toggle(TerminalPredictiveEchoSetting.configPath, TerminalPredictiveEchoSetting.fallback) { $0.terminalPredictiveLocalEcho },
        choice(AnimationSpeedSetting.configPath, AnimationSpeedSetting.fallback) { $0.animationSpeed },
        toggle(PaneAnimationsSetting.configPath, PaneAnimationsSetting.fallback) { $0.paneAnimations },
        choice(CalmModeSetting.configPath, CalmModeSetting.fallback) { $0.calmMode },
        toggle(ReducedBackgroundsSetting.configPath, ReducedBackgroundsSetting.fallback) { $0.reducedBackgrounds },
        toggle(AgentGlowSetting.configPath, AgentGlowSetting.fallback) { $0.agentGlow },
        toggle(PreviousGlassSetting.configPath, PreviousGlassSetting.fallback) { $0.previousGlass },
        toggle(LiquidGlassSetting.configPath, LiquidGlassSetting.fallback) { $0.liquidGlass },
        choice(WindowTitlebarSetting.configPath, WindowTitlebarSetting.fallback) { $0.titlebar },
        choice(TitlebarButtonsSetting.configPath, TitlebarButtonsSetting.fallback) { $0.titlebarButtons },
        choice(PlusButtonSetting.configPath, PlusButtonSetting.fallback) { $0.plusButton },
        choice(PaneBackgroundsSetting.configPath, PaneBackgroundsSetting.fallback) { $0.paneBackgrounds },
        toggle(NewTerminalWorkspaceSetting.configPath, NewTerminalWorkspaceSetting.fallback) { $0.newTerminalOpensWorkspace },
        toggle(NativeNewTabPageSetting.configPath, NativeNewTabPageSetting.fallback) { $0.nativeNewTabPage },
        choice(TabShellIconThemeSetting.configPath, TabShellIconThemeSetting.fallback) { $0.tabShellIconTheme },
        toggle(VerticalTabsSetting.configPath, VerticalTabsSetting.fallback) { $0.verticalTabs },
        toggle(VerticalTabsSetting.expandOnHoverPath, VerticalTabsSetting.expandOnHoverDefault) { $0.verticalTabsExpandOnHover },
        toggle(LoneChatTabSetting.configPath, LoneChatTabSetting.fallback) { $0.hideLoneChatTab },
        toggle(SwapCmdTAndCmdNSetting.configPath, SwapCmdTAndCmdNSetting.fallback) { $0.swapCmdTAndCmdN },
    ]

    /// Values of every shape a file can hold, valid or not, beside each row's own valid values.
    static let badValues: [JSONValue] = [.null, .string(""), .string("yes"), .string("TRUE"), .number(0), .number(1),
                                         .array([]), .array([.bool(true)]), .object([:]), .object(["value": .bool(true)])]

    /// `root` with `value` at `path`.
    static func setting(_ path: [String], to value: JSONValue, in root: JSONValue = .object([:])) -> JSONValue {
        guard let head = path.first else { return value }
        var members = root.objectValue ?? [:]
        members[head] = setting(Array(path.dropFirst()), to: value, in: members[head] ?? .object([:]))
        return .object(members)
    }

    static func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    /// The snapshot's value and diagnostic for `row` equal the deleted Swift's on `root`.
    static func expectParity(_ row: Row, _ root: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) {
        let snapshot = parse(root)
        let (value, diagnostic) = row.oracle(root)
        #expect(row.field(snapshot) == value, "\(row.key) in \(root.compactText)", sourceLocation: sourceLocation)
        let found = snapshot.diagnostics.filter { $0.path == row.key }
        #expect(found == (diagnostic.map { [$0] } ?? []), "\(row.key) in \(root.compactText)", sourceLocation: sourceLocation)
    }

    @Test(arguments: SnapshotRustParityTests.rows) func everyValueMatchesTheDeletedSwift(_ row: Row) {
        Self.expectParity(row, .object([:]))
        for value in row.samples + Self.badValues {
            Self.expectParity(row, Self.setting(row.path, to: value))
        }
        for choice in row.samples.compactMap(\.stringValue) {
            Self.expectParity(row, Self.setting(row.path, to: .string(choice.uppercased())))
            Self.expectParity(row, Self.setting(row.path, to: .string(" \(choice)")))
        }
    }

    /// A parent that is not an object (`"browser": 5`) reads as absent, as the deleted Swift did.
    @Test(arguments: SnapshotRustParityTests.rows) func aParentThatIsNotAnObjectIsAbsent(_ row: Row) {
        guard row.path.count > 1 else { return }
        Self.expectParity(row, Self.setting(Array(row.path.dropLast()), to: .number(5)))
        Self.expectParity(row, Self.setting(Array(row.path.dropLast()), to: .string("on")))
    }

    /// Every row set wrong at once: each gets its own diagnostic, in the same sorted order as before.
    @Test func everyRowWrongAtOnceGivesTheSameDiagnostics() {
        var root: JSONValue = .object([:])
        for row in Self.rows { root = Self.setting(row.path, to: .string("nope"), in: root) }
        let snapshot = Self.parse(root)
        let keys = Set(Self.rows.map(\.key))
        let expected = Self.rows.compactMap { $0.oracle(root).1 }.sorted { $0.path < $1.path }
        #expect(snapshot.diagnostics.filter { keys.contains($0.path) } == expected)
        for row in Self.rows { #expect(row.field(snapshot) == row.oracle(root).0, "\(row.key)") }
    }

    /// Every row set to a valid non-default value at once.
    @Test func everyRowSetAtOnceMatches() {
        var root: JSONValue = .object([:])
        for row in Self.rows {
            let value = row.samples.first { $0 != row.oracle(.object([:])).0 } ?? row.samples[0]
            root = Self.setting(row.path, to: value, in: root)
        }
        let snapshot = Self.parse(root)
        for row in Self.rows {
            #expect(row.field(snapshot) == row.oracle(root).0, "\(row.key)")
            #expect(!snapshot.diagnostics.contains { $0.path == row.key }, "\(row.key)")
        }
    }

    /// The retired keys the file still sets match the deleted Swift, sorted.
    @Test func retiredKeysMatchTheDeletedSwift() {
        let retired = SettingsSchema.retiredKeys.keys.sorted()
        #expect(!retired.isEmpty)
        #expect(Self.parse(.object([:])).retiredKeys == Oracle.retiredKeys(.object([:])))
        var root: JSONValue = .object([:])
        for (index, key) in retired.enumerated() where index.isMultiple(of: 2) {
            root = Self.setting(key.split(separator: ".").map(String.init), to: .bool(true), in: root)
        }
        #expect(Self.parse(root).retiredKeys == Oracle.retiredKeys(root))
        #expect(!Self.parse(root).retiredKeys.isEmpty)
        let null = Self.setting(retired[0].split(separator: ".").map(String.init), to: .null)
        #expect(Self.parse(null).retiredKeys == Oracle.retiredKeys(null))
    }

    /// A root that is not an object is one `unreadable_file` diagnostic and every default, as before.
    @Test(arguments: [JSONValue.null, .array([]), .string("{}"), .number(1), .bool(true)])
    func aRootThatIsNotAnObjectIsUnreadable(_ root: JSONValue) {
        let snapshot = Self.parse(root)
        #expect(snapshot.diagnostics == [SettingsDiagnostic(kind: .unreadableFile, path: "", message: "root is not an object")])
        #expect(snapshot.retiredKeys.isEmpty)
        for row in Self.rows { #expect(row.field(snapshot) == row.oracle(.object([:])).0, "\(row.key)") }
    }

    /// The Vim key style still turns `browser.vimKeys` on over the file's value.
    @Test func theVimKeyStyleStillTurnsVimKeysOn() {
        let root = Self.setting(BrowserVimKeysSetting.configPath, to: .bool(false),
                                in: ["app": ["keyStyle": "vim"]])
        let snapshot = Self.parse(root)
        #expect(snapshot.keyboardStyle.keyStyle == .vim)
        #expect(snapshot.browserVimKeys)
    }
}

/// The Swift `CmuxConfigSnapshot.parse` used before step B: the one-key parse functions
/// (`BookmarksBarSetting.parse` and the rest, all one of these two bodies with their key's path,
/// fallback and choices), `parsePreviewFeatures`, the Labs toggles, and the retired-keys filter.
private enum Oracle {
    /// The deleted toggle body (`BookmarksBarSetting.parse`, `VerticalTabsSetting.parseToggle`, ...).
    static func toggle(_ root: JSONValue, path: [String], fallback: Bool) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
        }
        return (enabled, nil)
    }

    /// The deleted choice body (`CalmModeSetting.parse`, `PaneBackgroundsSetting.parse`, ...);
    /// `unquoted` is `HomeChiefBubbleStyleSetting.parse`'s wording.
    static func choice<Choice: CaseIterable & RawRepresentable>(
        _ root: JSONValue, path: [String], fallback: Choice, unquoted: Bool
    ) -> (Choice, SettingsDiagnostic?) where Choice.RawValue == String {
        guard let value = root.value(at: path) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = Choice(rawValue: text) else {
            let choices = unquoted
                ? Choice.allCases.map(\.rawValue).joined(separator: ", ")
                : Choice.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }

    /// The deleted retired-keys line of `CmuxConfigSnapshot.parse`.
    static func retiredKeys(_ root: JSONValue) -> [String] {
        SettingsSchema.retiredKeys.keys.filter { root.value(at: $0.split(separator: ".").map(String.init)) != nil }.sorted()
    }
}
