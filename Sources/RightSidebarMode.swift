import Foundation

/// Stable identifier for a first-party right-sidebar panel.
///
/// The raw value is persisted in `rightSidebar.mode`; presentation metadata and
/// feature availability live in ``RightSidebarPanelRegistry``. The type keeps
/// source compatibility for existing `.files`/`.find` call sites without
/// making the set of panels a closed enum.
struct RightSidebarMode: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    /// Immutable metadata cache used by value-type convenience properties.
    /// Availability is still evaluated against the caller's defaults store by
    /// ``RightSidebarPanelRegistry``; this cache only avoids rebuilding view
    /// descriptors for labels, symbols, and identity lookups on every render.
    private static let metadataRegistry = RightSidebarPanelRegistry()

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
    /// Cloud Machines, enabled by the remote rollout or local beta opt-in.
    static let machines = Self("machines")
    static let sourceControl = Self("sourceControl")
    /// Reserved for persisted custom-sidebar references; custom sidebars are
    /// rendered as pane surfaces rather than registry-backed right-sidebar tabs.
    static let customSidebar = Self("custom-sidebar")

    static var allCases: [RightSidebarMode] {
        metadataRegistry.descriptors.compactMap { RightSidebarMode(rawValue: $0.id) }
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
        Self.metadataRegistry.descriptor(for: self)?.title ?? rawValue
    }

    var symbolName: String {
        Self.metadataRegistry.descriptor(for: self)?.symbolName ?? "square"
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        Self.metadataRegistry.descriptor(for: self)?.shortcutAction
    }

    var canOpenAsPane: Bool {
        Self.metadataRegistry.descriptor(for: self)?.supportsTearOffPane == true
    }

    static var paneModes: [RightSidebarMode] {
        metadataRegistry.descriptors.compactMap { descriptor in
            guard descriptor.supportsTearOffPane else { return nil }
            return RightSidebarMode(rawValue: descriptor.id)
        }
    }
}
