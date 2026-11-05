public import AppKit
import CmuxNextDesign
import CmuxNextHome
import Foundation

/// The card's parts per profile tab (Lawrence 2026-11-04, the Chief profile panel): Details, Settings
/// and Computer each show one section of this card, so every Chief setting shows in exactly one tab.
@MainActor
final class HomeChiefSettingsSections {
    private let details = NSStackView()
    private let settings = NSStackView()
    private let computer = NSStackView()

    subscript(tab: HomeChiefProfileTab) -> NSStackView {
        switch tab {
        case .details: details
        case .settings: settings
        case .computer: computer
        }
    }
}

extension HomeChiefSettingsView {
    /// The harness items the picker offers: the official engines (``ChiefBackend/official``:
    /// the user's own Claude login, Codex, Muse Code, and UniiChat, acpmux's built-in `unii`); the
    /// CodeRouter route (`claude-cr`) after Claude only when this Chief's acpmux has one
    /// configured; then every other harness `listed` by this Mac's acpmux
    /// (`_acpmux/harnesses`), in its order (Lawrence 2026-10-23: "chief can choose between
    /// literally all the acpmux stuff"). A current choice outside the list still shows (`fill`).
    nonisolated static func harnesses(routeConfigured: Bool, listed: [String] = []) -> [String] {
        let official = ChiefBackend.official.map(\.id)
        var offered = routeConfigured
            ? [ChiefBackend.claude.id, "claude-cr"] + official.filter { $0 != ChiefBackend.claude.id }
            : official
        var seen = Set(offered)
        for id in listed where !id.isEmpty && seen.insert(id).inserted { offered.append(id) }
        return offered
    }

    /// The harness picker's items: each harness with the name the app shows for it.
    nonisolated static func harnessItems(routeConfigured: Bool, listed: [String] = []) -> [(value: String, title: String)] {
        harnesses(routeConfigured: routeConfigured, listed: listed).map { ($0, ChiefBackend.title(for: $0)) }
    }

    /// Shows only `tab`'s section of the card (nil: every section, the whole card). The note line
    /// shows above any of them.
    public func showSection(_ tab: HomeChiefProfileTab?) {
        var changed = false
        for each in HomeChiefProfileTab.allCases {
            let hidden = tab != nil && each != tab
            if sections[each].isHidden != hidden {
                sections[each].isHidden = hidden
                changed = true
            }
        }
        if changed { onResize() }
    }

    /// The tab whose section holds `view` (tests: each setting is in exactly one tab); nil outside them.
    func tab(of view: NSView) -> HomeChiefProfileTab? {
        HomeChiefProfileTab.allCases.first { view.isDescendant(of: sections[$0]) }
    }

    /// The wider gap after `view`, a group's last row, in the stack that holds it.
    func gap(after view: NSView) {
        (view.superview as? NSStackView)?.setCustomSpacing(Metrics.space4, after: view)
    }

    @objc func showMemory() {
        onShowMemory()
    }

    /// All Chief Settings… and Edit Chief…: Settings > Chief, the full Chief editor.
    @objc func openAllSettings() {
        onAllSettings()
    }

    @objc func openTraces() {
        NSWorkspace.shared.revealInBackground([HomeChiefFiles(muxHome: muxHome).traceDirectory])
    }
}
