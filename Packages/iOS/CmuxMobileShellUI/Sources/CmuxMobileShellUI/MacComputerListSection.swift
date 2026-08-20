import CMUXMobileCore
import CmuxMobileSupport
import Foundation

/// One route-kind section of the Connections list: a connection method plus
/// the paired Macs advertising a route of that kind. `kind == nil` collects
/// pairings with no advertised route, so they stay visible (and hideable)
/// instead of vanishing from the screen.
///
/// A Mac advertising several methods appears once per method — the visible
/// row identity is (device, build, route kind). Each per-kind row carries that
/// kind's own endpoint in ``MacComputerSnapshot/routeDescription``, while the
/// snapshot `id` stays the pairing id, so visibility toggles and connection
/// state affect every row of the same pairing consistently.
///
/// The section for the user's SELECTED connection method (`selectedKind`,
/// always set: it mirrors the Settings "Connection Method" choice) is always
/// present — even with no matching routes — pinned to the top and marked
/// ``isActive``: "this is the method you selected; only its routes are
/// attempted". Every other section renders dimmed. Row-level Connected vs
/// Standby is keyed separately to `carryingKind`, the route actually holding
/// the live session, so a fallback connection outside the selected method
/// still displays truthfully.
struct MacComputerListSection: Equatable, Identifiable {
    /// The connection method, or `nil` for the trailing no-route section.
    let kind: CmxAttachTransportKind?
    let computers: [MacComputerSnapshot]
    /// Whether this section is the user's selected connection method.
    var isActive: Bool = false

    var id: String { kind?.rawValue ?? "no-route" }

    /// Section order matches dial preference: automatic peer routes first.
    private static let kindOrder: [CmxAttachTransportKind] = [
        .iroh, .tailscale, .websocket, .debugLoopback,
    ]

    /// Debug-loopback routes are a dev tool; production builds never show a
    /// Debug section (the routes still exist in the store, they just don't
    /// render a list section).
    static var includesDebugSection: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var title: String {
        kind?.mobileConnectionMethodName
            ?? L10n.string("mobile.connections.section.noRoute", defaultValue: "No Route")
    }

    /// Group per-Mac snapshots into route-kind sections, preserving the input
    /// (last-seen-newest-first) order within each section. The selected
    /// method's section is always returned (empty when nothing advertises it)
    /// and pinned first; other sections appear only when non-empty.
    /// `carryingKind` is the route kind holding the live foreground session
    /// (nil when disconnected) and only affects per-row Connected/Standby.
    static func sections(
        from snapshots: [MacComputerSnapshot],
        selectedKind: CmxAttachTransportKind,
        carryingKind: CmxAttachTransportKind? = nil,
        includeDebug: Bool = Self.includesDebugSection
    ) -> [MacComputerListSection] {
        var byKind: [CmxAttachTransportKind: [MacComputerSnapshot]] = [:]
        var routeless: [MacComputerSnapshot] = []
        for snapshot in snapshots {
            var kinds = advertisedKinds(of: snapshot.routes)
            if !includeDebug {
                kinds.removeAll { $0 == .debugLoopback }
            }
            if kinds.isEmpty {
                routeless.append(snapshot)
                continue
            }
            for kind in kinds {
                var row = snapshot
                row.routeKind = kind
                row.routeDescription = CmxAttachRoute.deviceTreeRouteDescription(
                    for: snapshot.routes,
                    kind: kind
                )
                // A connected Mac's session rides exactly one route; its rows
                // under every other method are standby routes, not live ones.
                // (The store only exposes the foreground connection's route, so
                // secondary-connected Macs inherit the same carrying kind.)
                if let carryingKind,
                   kind != carryingKind,
                   snapshot.connectionStatus == .connected {
                    row.isStandbyRoute = true
                }
                byKind[kind, default: []].append(row)
            }
        }
        // The selected method's section always exists, so the Active marker
        // has somewhere to live even before any matching route is stored.
        if byKind[selectedKind] == nil {
            byKind[selectedKind] = []
        }
        var sections = kindOrder.compactMap { kind in
            byKind[kind].map {
                MacComputerListSection(kind: kind, computers: $0, isActive: kind == selectedKind)
            }
        }
        if !routeless.isEmpty {
            sections.append(MacComputerListSection(kind: nil, computers: routeless))
        }
        // The selected method always leads, whatever the dial order says.
        // Partition (not sort) so the remaining order stays deterministic.
        return sections.filter(\.isActive) + sections.filter { !$0.isActive }
    }

    /// The distinct route kinds a pairing advertises, first-seen order.
    private static func advertisedKinds(of routes: [CmxAttachRoute]) -> [CmxAttachTransportKind] {
        var seen = Set<CmxAttachTransportKind>()
        return routes.compactMap { seen.insert($0.kind).inserted ? $0.kind : nil }
    }
}

extension CmxAttachTransportKind {
    /// User-facing name of the connection method, shared by the Connections
    /// list section headers and the per-computer route diagnostics.
    var mobileConnectionMethodName: String {
        switch self {
        case .iroh:
            L10n.string("mobile.connections.method.autoConnect", defaultValue: "Auto-Connect")
        case .tailscale:
            L10n.string("mobile.connections.method.tailscale", defaultValue: "Tailscale")
        case .websocket:
            L10n.string("mobile.connections.method.websocket", defaultValue: "WebSocket")
        case .debugLoopback:
            L10n.string("mobile.connections.method.debug", defaultValue: "Debug")
        }
    }
}
