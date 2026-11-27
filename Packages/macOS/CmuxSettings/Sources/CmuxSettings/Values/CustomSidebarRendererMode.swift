import Foundation

/// Where a custom sidebar's interpreted source is rendered.
///
/// Stored under the catalog entry ``CustomSidebarsCatalogSection/renderer``
/// (`customSidebars.renderer` in `~/.config/cmux/cmux.json`). The raw values
/// are the on-disk strings, so they must not be renamed without a migration.
public enum CustomSidebarRendererMode: String, CaseIterable, Sendable, SettingCodable {
    /// The containment lane: an out-of-process render worker
    /// interprets and renders the file; the host only composites the worker's
    /// remote layer, so an interpreter fault cannot crash the host. Input is
    /// limited to forwarded clicks (no hover, focus, or keyboard).
    case remote

    /// The default lane: the file is interpreted and rendered as real
    /// SwiftUI in the host process, gaining native input (hover, focus,
    /// keyboard) and same-frame resize. A renderer fault shares the host
    /// process, so only use this for sidebars you authored yourself.
    case inProcess
}
