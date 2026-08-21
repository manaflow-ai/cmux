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

/// How machines and workspaces compose in the sidebar region. Wilder
/// alternatives to the two-column regime, runtime-switchable like the
/// boundary styles.
enum SidebarNavigationLayout: String, CaseIterable, Identifiable {
    /// Machines column + workspaces column (the current regime).
    case twoColumns
    /// One sidebar; machines are chips above the workspace list.
    case machineChips
    /// One sidebar; a dropdown machine picker above the workspace list.
    case machineDropdown
    /// One sidebar; machines are an icon dock at the bottom.
    case machineDock

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .twoColumns: return "Two Columns"
        case .machineChips: return "Machine Chips"
        case .machineDropdown: return "Machine Dropdown"
        case .machineDock: return "Bottom Machine Dock"
        }
    }

    var debugDetail: String {
        switch self {
        case .twoColumns: return "Machines column next to the workspaces column"
        case .machineChips: return "One sidebar; machines as chips at the top"
        case .machineDropdown: return "One sidebar; machine picker menu at the top"
        case .machineDock: return "One sidebar; machine icons docked at the bottom"
        }
    }

    var showsMachinesColumn: Bool { self == .twoColumns }
}

/// Shared runtime store, persisted in UserDefaults (debug/dogfood tuning
/// only, deliberately not part of session persistence).
@MainActor
final class SidebarBoundaryStyleStore: ObservableObject {
    static let shared = SidebarBoundaryStyleStore()
    private static let defaultsKey = "debug.sidebarBoundaryStyle"
    private static let layoutDefaultsKey = "debug.sidebarNavigationLayout"

    @Published var style: SidebarBoundaryStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.defaultsKey)
        }
    }

    @Published var navigationLayout: SidebarNavigationLayout {
        didSet {
            UserDefaults.standard.set(
                navigationLayout.rawValue,
                forKey: Self.layoutDefaultsKey
            )
        }
    }

    private init() {
        style = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(SidebarBoundaryStyle.init(rawValue:)) ?? .chromeBands
        navigationLayout = UserDefaults.standard.string(forKey: Self.layoutDefaultsKey)
            .flatMap(SidebarNavigationLayout.init(rawValue:)) ?? .twoColumns
    }
}

extension SidebarBoundaryStyle {
    /// One-line description shown in the debug picker window.
    var debugDetail: String {
        switch self {
        case .fullLine:
            return "Full-height hairline between the columns"
        case .insetLine:
            return "Hairline clears the titlebar and footer strips"
        case .railWash:
            return "No line; machines column slightly darker"
        case .chromeBands:
            return "Tinted top/bottom bands; line between them"
        case .bandsAndWash:
            return "Tinted bands plus the wash, no line"
        case .spacingOnly:
            return "Nothing; spacing alone"
        }
    }
}

/// Floating picker window (Debug > Debug Windows > Sidebar Boundary…) so the
/// variants can be clicked through while watching the sidebar live.
final class SidebarBoundaryDebugWindowController: ReleasingWindowController {
    static let shared = SidebarBoundaryDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Boundary"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarBoundaryDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarBoundaryDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

private struct SidebarBoundaryDebugView: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Applies live and persists across relaunches.")
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)

                Text("NAVIGATION LAYOUT")
                    .cmuxFont(size: 10, weight: .semibold)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)
                ForEach(SidebarNavigationLayout.allCases) { layout in
                    Button {
                        store.navigationLayout = layout
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(
                                systemName: store.navigationLayout == layout
                                    ? "largecircle.fill.circle"
                                    : "circle"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(
                                store.navigationLayout == layout
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(layout.menuTitle)
                                    .cmuxFont(size: 12)
                                Text(layout.debugDetail)
                                    .cmuxFont(size: 10.5)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    store.navigationLayout == layout
                                        ? Color(nsColor: .quaternaryLabelColor)
                                        : .clear
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                Text("COLUMN BOUNDARY (two-column layout)")
                    .cmuxFont(size: 10, weight: .semibold)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(SidebarBoundaryStyle.allCases) { style in
                    Button {
                        store.style = style
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(
                                systemName: store.style == style
                                    ? "largecircle.fill.circle"
                                    : "circle"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(
                                store.style == style ? Color.accentColor : Color.secondary
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(style.menuTitle)
                                    .cmuxFont(size: 12)
                                Text(style.debugDetail)
                                    .cmuxFont(size: 10.5)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    store.style == style
                                        ? Color(nsColor: .quaternaryLabelColor)
                                        : .clear
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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


/// Shows content only for the matching navigation layout (observing leaf so
/// ContentView's body never reads the store).
struct SidebarNavigationLayoutGate<Content: View>: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared
    let requiresMachinesColumn: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !requiresMachinesColumn || store.navigationLayout.showsMachinesColumn {
            content()
        }
    }
}

/// Composes machines and workspaces per the selected navigation layout.
/// Prototype spacing; the winning layout gets a real polish pass.
struct SidebarNavigationArrangementView<MachinesColumn: View, Workspaces: View>: View {
    @ObservedObject private var store = SidebarBoundaryStyleStore.shared
    let leadingWidth: CGFloat
    let trailingWidth: CGFloat
    let totalWidth: CGFloat
    let trailingIdentity: String
    @ViewBuilder let machines: () -> MachinesColumn
    @ViewBuilder let workspaces: () -> Workspaces

    var body: some View {
        switch store.navigationLayout {
        case .twoColumns:
            SidebarColumnsContainer(
                leadingWidth: leadingWidth,
                trailingWidth: trailingWidth,
                trailingIdentity: trailingIdentity,
                leading: machines,
                trailing: workspaces
            )
        case .machineChips:
            VStack(spacing: 2) {
                SidebarMachineChipStrip()
                    .padding(.top, WindowChromeMetrics.appTitlebarHeight + 4)
                workspaces()
                    .id(trailingIdentity)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: max(0, totalWidth))
            .clipped()
        case .machineDropdown:
            VStack(spacing: 2) {
                SidebarMachineDropdown()
                    .padding(.top, WindowChromeMetrics.appTitlebarHeight + 4)
                workspaces()
                    .id(trailingIdentity)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: max(0, totalWidth))
            .clipped()
        case .machineDock:
            VStack(spacing: 0) {
                workspaces()
                    .id(trailingIdentity)
                    .frame(maxHeight: .infinity)
                SidebarMachineDock()
                    .padding(.bottom, SidebarChromeBandMetrics.bottomBandHeight)
            }
            .frame(width: max(0, totalWidth))
            .clipped()
        }
    }
}
