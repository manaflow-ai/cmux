import AppKit
import CmuxAppKitSupportUI
import Combine
import Foundation
import SwiftUI

/// Boundary treatment between the machines column, the workspaces column,
/// and the window chrome. Runtime-switchable (Debug menu, debug socket) so
/// variants can be compared live in one build; once one wins, it becomes
/// the only implementation and this store goes away.
enum SidebarBoundaryStyle: String, CaseIterable, Identifiable {
    /// Full-height hairline between the columns.
    case fullLine
    /// Hairline spanning the list band only (clears titlebar and footer).
    case insetLine
    /// No line; the machines column carries a slightly darker wash.
    case railWash
    /// Tinted titlebar and footer bands; hairline between the bands.
    case chromeBands
    /// Tinted bands plus the rail wash, no vertical line.
    case bandsAndWash
    /// Nothing: columns separate by spacing alone.
    case spacingOnly

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .fullLine: return "Full Line"
        case .insetLine: return "Inset Line"
        case .railWash: return "Rail Wash"
        case .chromeBands: return "Chrome Bands + Line"
        case .bandsAndWash: return "Chrome Bands + Wash"
        case .spacingOnly: return "Spacing Only"
        }
    }

    var drawsColumnLine: Bool {
        switch self {
        case .fullLine, .insetLine, .chromeBands: return true
        case .railWash, .bandsAndWash, .spacingOnly: return false
        }
    }

    /// Whether the column line clears the titlebar and footer strips.
    var lineSpansListBandOnly: Bool {
        switch self {
        case .insetLine, .chromeBands: return true
        case .fullLine, .railWash, .bandsAndWash, .spacingOnly: return false
        }
    }

    var drawsRailWash: Bool {
        switch self {
        case .railWash, .bandsAndWash: return true
        case .fullLine, .insetLine, .chromeBands, .spacingOnly: return false
        }
    }

    var drawsChromeBands: Bool {
        switch self {
        case .chromeBands, .bandsAndWash: return true
        case .fullLine, .insetLine, .railWash, .spacingOnly: return false
        }
    }

    /// Bands styles extend the titlebar hairline across the sidebar region;
    /// the others keep the original terminal-side-only line.
    var titlebarBorderSpansSidebar: Bool { drawsChromeBands }
}

/// Shared runtime store, persisted in UserDefaults (debug/dogfood tuning
/// only, deliberately not part of session persistence).
@MainActor
final class SidebarBoundaryStyleStore: ObservableObject {
    static let shared = SidebarBoundaryStyleStore()
    private static let defaultsKey = "debug.sidebarBoundaryStyle"

    @Published var style: SidebarBoundaryStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        style = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(SidebarBoundaryStyle.init(rawValue:)) ?? .chromeBands
    }
}

/// Debug-menu picker for the boundary style.
struct SidebarBoundaryStyleMenuButtons: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared

    var body: some View {
        Picker("Sidebar Boundary", selection: $store.style) {
            ForEach(SidebarBoundaryStyle.allCases) { style in
                Text(style.menuTitle).tag(style)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Top chrome band over the sidebar region (style-gated observing leaf so
/// style flips invalidate only this view).
struct SidebarChromeTopBandView: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared
    let width: CGFloat

    var body: some View {
        if store.style.drawsChromeBands {
            SidebarChromeBandMetrics.bandFill
                .frame(
                    width: max(0, width),
                    height: SidebarChromeBandMetrics.topBandHeight
                )
                .allowsHitTesting(false)
        }
    }
}

/// Footer band background (tint + top hairline) behind the region footer.
struct SidebarChromeFooterBandBackground: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared

    var body: some View {
        if store.style.drawsChromeBands {
            SidebarChromeBandMetrics.bandFill
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.72))
                        .frame(height: 1)
                }
        }
    }
}

/// The machines column's trailing edge: line and/or wash per style.
struct SidebarColumnBoundaryEdge: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared

    var body: some View {
        if store.style.drawsColumnLine {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.72))
                .frame(width: 1)
                .padding(
                    .top,
                    store.style.lineSpansListBandOnly
                        ? SidebarChromeBandMetrics.topBandHeight
                        : 0
                )
                .padding(
                    .bottom,
                    store.style.lineSpansListBandOnly
                        ? SidebarChromeBandMetrics.bottomBandHeight
                        : 0
                )
                .allowsHitTesting(false)
        }
    }
}

/// The machines column's wash background per style.
struct SidebarColumnRailWash: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if store.style.drawsRailWash {
            Color.black.opacity(colorScheme == .dark ? 0.14 : 0.05)
                .allowsHitTesting(false)
        }
    }
}

/// Titlebar bottom hairline whose sidebar-region span follows the style.
struct SidebarTitlebarBottomBorder: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared
    @ObservedObject var layout: SidebarLayoutModel
    let backgroundColor: NSColor
    let sidebarVisible: Bool

    var body: some View {
        WindowChromeBorder(
            orientation: .horizontal,
            backgroundColor: backgroundColor
        )
        .padding(
            .leading,
            (sidebarVisible && !store.style.titlebarBorderSpansSidebar)
                ? layout.regionWidth
                : 0
        )
    }
}
