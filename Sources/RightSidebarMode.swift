import Foundation

/// Stable identifier for a first-party right-sidebar panel.
///
/// The raw value is persisted in `rightSidebar.mode`; presentation metadata and
/// feature availability live in ``RightSidebarPanelRegistry`` so adding a
/// panel does not require another switch in the sidebar container.
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock
    case sourceControl

    var label: String {
        RightSidebarPanelRegistry.descriptor(for: self)?.title ?? rawValue
    }

    var symbolName: String {
        RightSidebarPanelRegistry.descriptor(for: self)?.symbolName ?? "square"
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        RightSidebarPanelRegistry.descriptor(for: self)?.shortcutAction
    }

    var canOpenAsPane: Bool {
        RightSidebarPanelRegistry.descriptor(for: self)?.supportsTearOffPane == true
    }

    static var paneModes: [RightSidebarMode] {
        RightSidebarPanelRegistry.descriptors().compactMap { descriptor in
            guard descriptor.supportsTearOffPane else { return nil }
            return RightSidebarMode(rawValue: descriptor.id)
        }
    }
}
