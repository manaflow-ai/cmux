import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// What a person with no settings sees, as text: the sidebar drawn from an empty config (the golden look screen's
/// `cmux` row: two project groups, a loose shell, one chat running a subagent), every `sidebar.*` preference that
/// shapes it, and every look or arm the app chooses by default (each toggle and choice in Debug Settings).
///
/// Leo, 2026-11-24 00:50Z, after cmux#52340 (sidebar row layouts) and the group look Lawrence asked about ("who
/// changed how groups look like?"): "in general we just wanna make sure in future e.g. we dont accidentally
/// unintnteially merge a weird customization as a default thingy". A customization is opt-in; this file is the
/// default it must leave alone. A change to it is a change to everyone's app, so land-judge's
/// removal-merged-unnoticed rule (leo-workspace tools/silent_removal.py, "default render") refuses a PR that
/// changes it unless its body has a `changes default: Leo, YYYY-MM-DD: "..."` line. Class page: cmuxterm-hq
/// docs/handbook/customization-leaked-into-default.md.
///
/// A PR that means to change the default regenerates the baseline with `CMUX_UPDATE_DEFAULT_RENDER=1` and quotes Leo.
@MainActor @Suite(.serialized) struct DefaultRenderBaselineTests {
    static let baseline = "Packages/macOS/CmuxNext/Tests/Fixtures/default-render/native.txt"
    /// A fixed clock: ages and folds read the same on every run.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func sections() -> [SidebarSection] {
        var sections = AAGoldenLookGalleryTests.sections(now: now)
        // One chat runs a subagent: what a row draws for it with the session tree at its default.
        if case .group(var atlas) = sections[0].nodes[0] {
            atlas.workspaces[1].subagents = SidebarSubagents(items: [
                SidebarSubagent(id: "sub-1", title: "Read the checkout test logs", state: .running, tab: TabID("t-sub-1")),
            ])
            sections[0].nodes[0] = .group(atlas)
        }
        return sections
    }

    /// The default `sidebar.*` preferences, one `name = value` line each.
    static func preferenceLines(_ preferences: SidebarSectionsPreferences) -> [String] {
        Mirror(reflecting: preferences).children.compactMap { child in
            child.label.map { "sidebar.\($0) = \(describe(child.value))" }
        }
    }

    /// Every toggle and choice tunable's default: a look or arm the app draws without an override. Numbers, colors and
    /// springs are tuning, not a look, and stay out.
    static func tunableLines() -> [String] {
        TunableCatalog.all.compactMap { descriptor -> String? in
            switch descriptor.kind {
            case .bool, .choice: "tunable \(descriptor.key) = \(TunableExport.swiftLiteral(descriptor.defaultValue))"
            default: nil
            }
        }.sorted()
    }

    /// The layout's rows, each with the fields that differ from an empty one.
    static func rowLines(_ layout: SidebarLayout) -> [String] {
        layout.rows.map { row in
            var parts = ["row \(describe(row.key))", "height \(row.height)", "depth \(row.depth)"]
            if row.isCollapsed { parts.append("collapsed") }
            if row.childCount > 0 { parts.append("children \(row.childCount)") }
            if let content = row.content {
                for child in Mirror(reflecting: content).children {
                    guard let label = child.label else { continue }
                    let value = describe(child.value)
                    if ["nil", "false", "[]", "0", "0.0", "standard", "dot", "none"].contains(value) { continue }
                    parts.append("\(label) \(value)")
                }
            }
            return parts.joined(separator: " | ")
        }
    }

    static func describe(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let some = mirror.children.first?.value else { return "nil" }
            return describe(some)
        }
        return String(describing: value).replacingOccurrences(of: "\n", with: " ")
    }

    static func render() -> String {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        let preferences = snapshot.sidebarSections
        let model = SidebarModel(sections: sections(), activeWorkspaceID: AAGoldenLookGalleryTests.selected)
        model.applyListPreferences(preferences)
        var options = model.listOptions()
        options.now = now
        let layout = SidebarLayout.make(sections: model.sections, metrics: .standard, options: options)
        let lines = ["# What a person with no settings sees (DefaultRenderBaselineTests). Changing a line changes everyone's",
                     "# app: the PR quotes Leo in a `changes default: Leo, YYYY-MM-DD: \"...\"` line (land-judge refuses it",
                     "# otherwise). Regenerate: CMUX_UPDATE_DEFAULT_RENDER=1.",
                     "", "## sidebar preferences"] + preferenceLines(preferences)
            + ["", "## group header", "group.background = \(describe(model.groupHeaderDetails.background))",
               "group.memberCount = \(describe(model.groupHeaderDetails.memberCount))",
               "group.unreadCount = \(describe(model.groupHeaderDetails.unreadCount))",
               "", "## sidebar rows (golden look fixture, no config)"] + rowLines(layout)
            + ["", "## looks and arms (toggle and choice tunables)"] + tunableLines()
        return lines.joined(separator: "\n") + "\n"
    }

    @Test func theDefaultRenderMatchesItsBaseline() throws {
        let url = AANestedGroupsGalleryTests.repoRoot.appending(path: Self.baseline)
        let drawn = Self.render()
        if ProcessInfo.processInfo.environment["CMUX_UPDATE_DEFAULT_RENDER"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try drawn.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let kept = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let before = Set(kept.split(separator: "\n", omittingEmptySubsequences: false))
        let after = Set(drawn.split(separator: "\n", omittingEmptySubsequences: false))
        let gone = kept.split(separator: "\n").filter { !after.contains($0) }
        let new = drawn.split(separator: "\n").filter { !before.contains($0) }
        if kept != drawn { print("default-render-begin\n\(drawn)default-render-end") }
        #expect(kept == drawn, """
            The no-settings render changed (\(Self.baseline)). A customization must leave the default alone: put the \
            change behind its setting. If the default is meant to change, regenerate with CMUX_UPDATE_DEFAULT_RENDER=1 \
            and add `changes default: Leo, YYYY-MM-DD: "..."` to the PR body.
            was:
            \(gone.joined(separator: "\n"))
            now:
            \(new.joined(separator: "\n"))
            """)
    }
}
