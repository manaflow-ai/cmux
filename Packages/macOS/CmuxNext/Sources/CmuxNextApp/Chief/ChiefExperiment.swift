import AppKit
import CmuxNextActions
import CmuxNextChief
import CmuxNextSettings
import CmuxNextSidebar

// Chief experiment (plans/cmux-next/chief.md; branch feat-cmux-next-chief
// only). The item is injected on this client at the top of the Home section
// (it is not a store item, so drags and Remove do not apply to it) and only
// when ~/.config/cmux/chief-experiment.json exists. A click opens one
// internal page tab per window with the chief conversation.

extension InternalPageID {
    static let chiefExperiment = InternalPageID(rawValue: "chief-experiment")
}

@MainActor
final class ChiefExperimentPage: InternalPageProvider {
    static let shared = ChiefExperimentPage()

    private var views: [String: ChiefView] = [:]

    var page: InternalPageID { .chiefExperiment }
    var title: String { ChiefStrings.title }
    var symbol: String { "brain" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let view = ChiefView()
        views[key] = view
        return view
    }

    func tabClosed(_ key: String) {
        views.removeValue(forKey: key)?.close()
    }

    /// `debug.chief`: every open Chief tab's state and a rendered PNG.
    func debugReport() -> CmuxNextSettings.JSONValue {
        .array(views.sorted { $0.key < $1.key }.map { key, view in
            let r = view.debugReport()
            return .object([
                "tab": .string(key),
                "connection": .string(r.connection),
                "me": r.me.map(CmuxNextSettings.JSONValue.string) ?? .null,
                "transcript_count": .number(Double(r.transcriptCount)),
                "visible_rows": .array(r.visibleRows.map(CmuxNextSettings.JSONValue.string)),
                "frame": .string(NSStringFromRect(r.frame)),
                "snapshot": r.snapshotPath.map(CmuxNextSettings.JSONValue.string) ?? .null,
            ])
        })
    }
}

nonisolated enum ChiefExperimentItem {
    static let id = LayoutItemID("itm_chief_experiment")
    static let kind = "chief_experiment"

    /// Whether this Mac has the experiment configured.
    static var isEnabled: Bool { ChiefExperimentConfig.load() != nil }

    /// `layout` with the chief item first in the Home section, unless it is there already.
    static func injected(into layout: SidebarLayoutDocument, enabled: Bool) -> SidebarLayoutDocument {
        guard enabled, layout.item(id) == nil,
              let index = layout.sections.firstIndex(where: { $0.id == SidebarLayoutDocument.topSectionID }) else { return layout }
        var out = layout
        out.sections[index].items.insert(LayoutItem(id: id, ref: LayoutItemRef(kind: kind, value: "chief")), at: 0)
        return out
    }

    static var info: SidebarItemInfo { SidebarItemInfo(title: ChiefStrings.title, symbol: "brain") }
}

/// `chief.show`: the one path the sidebar item, the palette and the CLI share.
enum ChiefExperimentHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        services.pages.register(ChiefExperimentPage.shared)
        registry.bind("chief.show", run: { invocation in
            _ = services.pages.show(.chiefExperiment, in: services.windows.active, focus: invocation.allowsViewChange)
        })
    }
}

extension SidebarBridge {
    /// Opens (or selects) the chief tab in the active window.
    func showChiefExperiment() {
        _ = services.registry.perform("chief.show", invocation: ActionInvocation(origin: .user))
    }
}
