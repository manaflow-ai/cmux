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
/// When the phone has a live foreground connection, the section whose kind is
/// carrying it (`activeKind`) sorts first and is marked ``isActive``; every
/// other section renders dimmed so the list reads "this is the method in use
/// right now". With no live connection nothing is dimmed and sections keep
/// dial-preference order.
struct MacComputerListSection: Equatable, Identifiable {
    /// The connection method, or `nil` for the trailing no-route section.
    let kind: CmxAttachTransportKind?
    let computers: [MacComputerSnapshot]
    /// Whether this section's method carries the phone's live connection.
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
    /// (last-seen-newest-first) order within each section. Only non-empty
    /// sections are returned. `activeKind` is the method carrying the phone's
    /// live connection (nil when disconnected): its section is flagged active
    /// and pinned to the top.
    static func sections(
        from snapshots: [MacComputerSnapshot],
        activeKind: CmxAttachTransportKind? = nil,
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
                row.routeDescription = CmxAttachRoute.deviceTreeRouteDescription(
                    for: snapshot.routes,
                    kind: kind
                )
                byKind[kind, default: []].append(row)
            }
        }
        var sections = kindOrder.compactMap { kind in
            byKind[kind].map {
                MacComputerListSection(kind: kind, computers: $0, isActive: kind == activeKind)
            }
        }
        if !routeless.isEmpty {
            sections.append(MacComputerListSection(kind: nil, computers: routeless))
        }
        // The live method always leads, whatever the dial preference says.
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
