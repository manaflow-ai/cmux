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
struct MacComputerListSection: Equatable, Identifiable {
    /// The connection method, or `nil` for the trailing no-route section.
    let kind: CmxAttachTransportKind?
    let computers: [MacComputerSnapshot]

    var id: String { kind?.rawValue ?? "no-route" }

    /// Section order matches dial preference: automatic peer routes first.
    private static let kindOrder: [CmxAttachTransportKind] = [
        .iroh, .tailscale, .websocket, .debugLoopback,
    ]

    var title: String {
        kind?.mobileConnectionMethodName
            ?? L10n.string("mobile.connections.section.noRoute", defaultValue: "No Route")
    }

    /// Group per-Mac snapshots into route-kind sections, preserving the input
    /// (last-seen-newest-first) order within each section. Only non-empty
    /// sections are returned.
    static func sections(from snapshots: [MacComputerSnapshot]) -> [MacComputerListSection] {
        var byKind: [CmxAttachTransportKind: [MacComputerSnapshot]] = [:]
        var routeless: [MacComputerSnapshot] = []
        for snapshot in snapshots {
            let kinds = advertisedKinds(of: snapshot.routes)
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
            byKind[kind].map { MacComputerListSection(kind: kind, computers: $0) }
        }
        if !routeless.isEmpty {
            sections.append(MacComputerListSection(kind: nil, computers: routeless))
        }
        return sections
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
