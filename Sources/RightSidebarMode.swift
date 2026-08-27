import Foundation

/// Stable identifier for a first-party right-sidebar panel.
///
/// The raw value is persisted in `rightSidebar.mode`; presentation metadata and
/// feature availability live in ``RightSidebarPanelRegistry``. The type keeps
/// source compatibility for existing `.files`/`.find` call sites without
/// making the set of panels a closed enum.
struct RightSidebarMode: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static let files = Self("files")
    static let find = Self("find")
    static let sessions = Self("sessions")
    static let feed = Self("feed")
    static let dock = Self("dock")
    static let sourceControl = Self("sourceControl")

    static var allCases: [RightSidebarMode] {
        RightSidebarPanelRegistry().descriptors.compactMap { RightSidebarMode(rawValue: $0.id) }
    }

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let mode = RightSidebarMode(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Right-sidebar mode must not be empty"
            )
        }
        self = mode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        RightSidebarPanelRegistry().descriptor(for: self)?.title ?? rawValue
    }

    var symbolName: String {
        RightSidebarPanelRegistry().descriptor(for: self)?.symbolName ?? "square"
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        RightSidebarPanelRegistry().descriptor(for: self)?.shortcutAction
    }

    var canOpenAsPane: Bool {
        RightSidebarPanelRegistry().descriptor(for: self)?.supportsTearOffPane == true
    }

    static var paneModes: [RightSidebarMode] {
        RightSidebarPanelRegistry().descriptors.compactMap { descriptor in
            guard descriptor.supportsTearOffPane else { return nil }
            return RightSidebarMode(rawValue: descriptor.id)
        }
    }
}
