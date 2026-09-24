#if DEBUG
import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSurfaceCatalogModel
import SwiftUI

// MARK: - Cloud sidebar spacing lab

/// Debug-only lab for tuning the real Cloud tree geometry against deliberately
/// adversarial names. The preview uses the production outline and row views, so
/// a spacing change is visible both here and in an open Cloud sidebar.
final class CloudSidebarDebugLabWindowController: ReleasingWindowController {
    private let settings: CloudSidebarDebugSettings

    init(settings: CloudSidebarDebugSettings) {
        self.settings = settings
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {}

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.cloudSidebarSpacing.title", defaultValue: "Cloud Sidebar Spacing Lab")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudSidebarDebugLab")
        window.minSize = NSSize(width: 860, height: 560)
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()
        window.contentView = NSHostingView(rootView: CloudSidebarDebugLabView(settings: settings))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow(activateApplication: true, orderFrontRegardless: true)
        window?.makeKey()
    }
}

private struct CloudSidebarDebugLabView: View {
    static let defaultPreviewWidth = 360.0

    @State private var selectedStyleID = CloudTreeStyleStore.current.id
    @Bindable var settings: CloudSidebarDebugSettings
    @State private var previewWidth = Self.defaultPreviewWidth
    @State private var expansionStore = CloudSidebarDebugFixture.makeExpansionStore()

    private var selectedStyle: CloudTreeStyle {
        CloudTreeStyle.preset(id: selectedStyleID) ?? .defaultStyle
    }

    var body: some View {
        HStack(spacing: 0) {
            CloudSidebarDebugControls(
                selectedStyleID: $selectedStyleID,
                metrics: $settings.metrics,
                previewWidth: $previewWidth,
                selectedStyle: selectedStyle
            )
            .frame(width: 328)
            Divider()
            CloudSidebarDebugPreview(
                style: settings.metrics.resolvedStyle(selectedStyle),
                previewWidth: previewWidth,
                expansionStore: expansionStore
            )
        }
        .onChange(of: selectedStyleID) { _, value in
            guard let style = CloudTreeStyle.preset(id: value) else { return }
            CloudTreeStyleStore.current = style
        }
    }
}

private struct CloudSidebarDebugControls: View {
    @Binding var selectedStyleID: String
    @Binding var metrics: CloudSidebarDebugMetrics
    @Binding var previewWidth: Double
    let selectedStyle: CloudTreeStyle

    private func localizedStyleName(_ style: CloudTreeStyle) -> String {
        switch style.id {
        case "compact": return String(localized: "debug.cloudSidebarSpacing.preset.compact", defaultValue: "Compact")
        case "chips": return String(localized: "debug.cloudSidebarSpacing.preset.chips", defaultValue: "Chips")
        case "sections": return String(localized: "debug.cloudSidebarSpacing.preset.sections", defaultValue: "Sections")
        case "ledger": return String(localized: "debug.cloudSidebarSpacing.preset.ledger", defaultValue: "Ledger")
        case "aero": return String(localized: "debug.cloudSidebarSpacing.preset.aero", defaultValue: "Aero")
        default: return style.name
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "debug.cloudSidebarSpacing.title", defaultValue: "Cloud Sidebar Spacing Lab"))
                    .cmuxFont(.headline)
                Text(String(localized: "debug.cloudSidebarSpacing.instructions", defaultValue: "Tune the production outline with long machine, workspace, terminal, browser, and port names. Values apply live to the Cloud sidebar."))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox(String(localized: "debug.cloudSidebarSpacing.style", defaultValue: "Style")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker(String(localized: "debug.cloudSidebarSpacing.preset", defaultValue: "Preset"), selection: $selectedStyleID) {
                                ForEach(CloudTreeStyle.presets) { style in
                                    Text(localizedStyleName(style)).tag(style.id)
                                }
                            }
                            .labelsHidden()
                            Spacer(minLength: 0)
                            CloudSidebarDebugResetButton(
                                title: String(localized: "debug.cloudSidebarSpacing.preset", defaultValue: "Preset"),
                                value: $selectedStyleID,
                                defaultValue: CloudTreeStyle.defaultStyle.id,
                                defaultLabel: localizedStyleName(.defaultStyle)
                            )
                        }
                        Text(String(format: String(localized: "debug.cloudSidebarSpacing.previewing", defaultValue: "Previewing %@, with spacing overrides below."), localizedStyleName(selectedStyle)))
                            .cmuxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }

                GroupBox(String(localized: "debug.cloudSidebarSpacing.outline", defaultValue: "Outline")) {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.previewWidth", defaultValue: "Preview width"), value: $previewWidth, range: 240...540, defaultValue: CloudSidebarDebugLabView.defaultPreviewWidth)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.rowHeight", defaultValue: "Row height"), value: $metrics.rowHeight, range: 16...44, defaultValue: CloudSidebarDebugMetrics.default.rowHeight)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.indent", defaultValue: "Indent / level"), value: $metrics.indentPerLevel, range: 6...24, defaultValue: CloudSidebarDebugMetrics.default.indentPerLevel)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.trailingInset", defaultValue: "Trailing inset"), value: $metrics.referenceInset, range: 0...28, defaultValue: CloudSidebarDebugMetrics.default.referenceInset)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.disclosureSlot", defaultValue: "Disclosure slot"), value: $metrics.disclosureSlot, range: 8...24, defaultValue: CloudSidebarDebugMetrics.default.disclosureSlot)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.disclosureGap", defaultValue: "Disclosure gap"), value: $metrics.disclosureGap, range: 0...14, defaultValue: CloudSidebarDebugMetrics.default.disclosureGap)
                    }
                    .padding(.top, 2)
                }

                GroupBox(String(localized: "debug.cloudSidebarSpacing.rowContent", defaultValue: "Row content")) {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.iconSlot", defaultValue: "Icon slot"), value: $metrics.iconSlot, range: 0...28, defaultValue: CloudSidebarDebugMetrics.default.iconSlot)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.iconGap", defaultValue: "Icon gap"), value: $metrics.iconGap, range: 0...16, defaultValue: CloudSidebarDebugMetrics.default.iconGap)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.badgeGap", defaultValue: "Machine badge gap"), value: $metrics.dotGap, range: 0...16, defaultValue: CloudSidebarDebugMetrics.default.dotGap)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.detailGap", defaultValue: "Detail gap"), value: $metrics.detailGap, range: 0...16, defaultValue: CloudSidebarDebugMetrics.default.detailGap)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.trailingGap", defaultValue: "Trailing gap"), value: $metrics.trailingGap, range: 0...24, defaultValue: CloudSidebarDebugMetrics.default.trailingGap)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.lineGap", defaultValue: "Machine line gap"), value: $metrics.machineLineSpacing, range: 0...8, defaultValue: CloudSidebarDebugMetrics.default.machineLineSpacing)
                        CloudSidebarDebugSliderRow(title: String(localized: "debug.cloudSidebarSpacing.verticalPadding", defaultValue: "Machine vertical pad"), value: $metrics.machineVerticalPadding, range: 0...12, defaultValue: CloudSidebarDebugMetrics.default.machineVerticalPadding)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 10) {
                    Button(String(localized: "debug.cloudSidebarSpacing.resetSpacing", defaultValue: "Reset spacing")) {
                        metrics = .default
                    }
                    Button(String(localized: "debug.cloudSidebarSpacing.copyConfig", defaultValue: "Copy config")) {
                        GhosttyApp.terminalPasteboard.writeString(
                            metrics.copyPayload(styleID: selectedStyleID),
                            to: .general
                        )
                    }
                }
                .controlSize(.small)

                Text(String(localized: "debug.cloudSidebarSpacing.fixtureNotes", defaultValue: "The fixture keeps every section expanded and uses names long enough to exercise truncation, nested rows, and the trailing edge."))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}

private struct CloudSidebarDebugSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 126, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text(String(format: "%.0f", value))
                .cmuxFont(.caption)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
            CloudSidebarDebugResetButton(
                title: title,
                value: $value,
                defaultValue: defaultValue,
                defaultLabel: String(format: "%.0f", defaultValue)
            )
        }
    }
}


private struct CloudSidebarDebugPreview: View {
    let style: CloudTreeStyle
    let previewWidth: Double
    let expansionStore: CloudTreeExpansionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .foregroundStyle(.tint)
                Text(String(localized: "debug.cloudSidebarSpacing.previewTitle", defaultValue: "Production outline preview"))
                    .font(.system(size: 12, weight: .semibold))
                Text(String(format: String(localized: "debug.cloudSidebarSpacing.widthPoints", defaultValue: "%d pt"), Int(previewWidth)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                CloudTreeOutlineView(
                    machines: CloudSidebarDebugFixture.machines,
                    snapshot: CloudSidebarDebugFixture.snapshot,
                    localWorkspaces: [],
                    machineActions: CloudSidebarDebugFixture.machineActions,
                    nodeActions: CloudSidebarDebugFixture.nodeActions,
                    expansionStore: expansionStore,
                    style: style
                )
                .frame(width: previewWidth)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                CloudSidebarDebugPreviewNotes()
                    .frame(maxWidth: 230, alignment: .leading)
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CloudSidebarDebugPreviewNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "debug.cloudSidebarSpacing.stressCases", defaultValue: "Stress cases"))
                .font(.system(size: 12, weight: .semibold))
            Label(String(localized: "debug.cloudSidebarSpacing.longNames", defaultValue: "Long machine and workspace names"), systemImage: "text.alignleft")
            Label(String(localized: "debug.cloudSidebarSpacing.longTerminals", defaultValue: "Long terminal titles"), systemImage: "terminal")
            Label(String(localized: "debug.cloudSidebarSpacing.browserPorts", defaultValue: "Browser URL and forwarded port rows"), systemImage: "globe")
            Label(String(localized: "debug.cloudSidebarSpacing.displaysResources", defaultValue: "Displays and resource metrics"), systemImage: "rectangle.on.rectangle")
            Text(String(localized: "debug.cloudSidebarSpacing.resizeNotes", defaultValue: "Resize the preview width to find the first awkward breakpoint. Keep the row readable before making the sidebar wider."))
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private enum CloudSidebarDebugFixture {
    static let machineID = "debug-long-machine-name-for-cloud-sidebar-spacing"
    static let machine = SurfaceMachineID.cloud(machineID)
    static let workspaceA = SurfaceRemoteWorkspace(
        id: "debug-workspace-release-candidate",
        name: "release-candidate / observability-and-telemetry / production-hotfix-review",
        index: 0,
        focused: true
    )
    static let workspaceB = SurfaceRemoteWorkspace(
        id: "debug-workspace-design-review",
        name: "design-review / navigation-redesign / accessibility-and-localization-pass",
        index: 1,
        focused: false
    )
    static let workspaceC = SurfaceRemoteWorkspace(
        id: "debug-workspace-empty-long-name",
        name: "long-lived-background-workspace-with-a-name-that-nearly-fills-the-sidebar",
        index: 2,
        focused: false
    )

    static var machines: [MachineSnapshot] {
        [
            MachineSnapshot(
                id: machineID,
                provider: "freestyle",
                image: "cmux-debug-stress-image",
                isDesktop: true,
                activity: .ready,
                createdAt: Date(timeIntervalSinceNow: -86_400 * 12),
                label: "production-hotfix-review-machine-with-a-deliberately-very-long-name",
                slug: "patient-otter",
                stats: VMStats(
                    state: .awake,
                    sampledAt: .now,
                    resourceSampledAt: .now,
                    cpus: 8,
                    cpuPercent: 63.4,
                    loadAverage1m: 3.1,
                    memoryTotalMb: 16_384,
                    memoryUsedMb: 12_288,
                    diskTotalMb: 102_400,
                    diskUsedMb: 77_824
                )
            )
        ]
    }

    static var snapshot: SurfaceCatalogSnapshot {
        let terminalA = terminal(
            key: "debug-terminal-build",
            title: "codex / build-and-test / release-candidate-validation-terminal",
            detail: "/home/cmux/projects/cmux/very/long/path/to/release-candidate"
        )
        let terminalB = terminal(
            key: "debug-terminal-server",
            title: "zsh / web-server / local-development-and-preview-process",
            detail: "/home/cmux/projects/cmux/web/apps/cloud-dashboard"
        )
        let terminalDetached = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "debug-terminal-detached"),
            title: "detached-background-terminal-with-a-long-process-title",
            detail: "/home/cmux/projects/cmux/scripts/fixtures",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
        let browser = browser(
            key: "debug-browser-docs",
            title: "Cloud dashboard / deployment timeline / production incident review",
            url: "https://observability.production.example.com/really/long/path/to/a/dashboard"
        )
        let port = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "port:4317"),
            title: "Forwarded development server on port 4317 with a long explanatory title",
            detail: "HTTP service",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: 4317,
            url: "http://debug-machine.internal:4317"
        )
        let display = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: "display:1"),
            title: "Desktop / browser automation / visual regression monitor",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspaceB,
            port: 6901,
            url: nil
        )

        return SurfaceCatalogSnapshot(
            machines: [
                SurfaceMachineInfo(
                    id: machine,
                    name: "production-hotfix-review-machine-with-a-deliberately-very-long-name",
                    status: "running",
                    image: "cmux-debug-stress-image",
                    hasDesktop: true,
                    memoryMb: 16_384,
                    diskMb: 102_400,
                    linkState: .connected,
                    linkError: nil,
                    cpuPercent: 63.4,
                    memoryUsedMb: 12_288,
                    diskUsedMb: 77_824,
                    remoteWorkspaces: [workspaceA, workspaceB, workspaceC],
                    privateAddress: "100.64.12.34"
                )
            ],
            resources: [terminalA, terminalB, terminalDetached, browser, port, display],
            projections: []
        )
    }

    private static func terminal(key: String, title: String, detail: String) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key),
            title: title,
            detail: detail,
            lifecycle: .running,
            agent: SurfaceAgentBadge(state: "working", source: "codex"),
            remoteWorkspace: workspaceA,
            port: nil,
            url: nil
        )
        resource.remoteViews = [
            SurfaceRemoteView(
                tabID: "tab-\(key)",
                workspace: workspaceA,
                screenID: "screen-1",
                paneID: "pane-\(key)",
                name: title,
                index: 0,
                focused: key == "debug-terminal-build"
            )
        ]
        return resource
    }

    private static func browser(key: String, title: String, url: String) -> SurfaceResource {
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: key),
            title: title,
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: workspaceB,
            port: nil,
            url: url
        )
        resource.remoteViews = [SurfaceRemoteView(tabID: "tab-\(key)", workspace: workspaceB)]
        return resource
    }

    @MainActor
    static func makeExpansionStore() -> CloudTreeExpansionStore {
        let defaults = UserDefaults(suiteName: "cmux.cloudSidebarDebugLab") ?? .standard
        defaults.removePersistentDomain(forName: "cmux.cloudSidebarDebugLab")
        let store = CloudTreeExpansionStore(defaults: defaults)
        let nodes = CloudTreeNodeBuilder.nodes(machines: machines, snapshot: snapshot, localWorkspaces: [])
        for node in CloudTreeNodeBuilder.flattened(nodes) where node.isExpandable {
            store.setExpanded(true, node: node)
        }
        return store
    }

    static let machineActions = MachineRowActions(
        openShell: { _ in },
        openDesktop: { _ in },
        runCommand: { _, _ in },
        confirmDelete: { _ in },
        promptRename: { _, _ in },
        resizeDisk: { _, _ in },
        promptUpgrade: {}
    )

    static let nodeActions = CloudTreeNodeActions(
        project: { _, _, _ in },
        projectRemoteView: { _, _, _, _ in },
        projectInLocalWorkspace: { _, _ in },
        projectRemoteViewInLocalWorkspace: { _, _, _ in },
        newTerminal: { _, _ in },
        openGroup: { _, _, _, _ in },
        openGroupAsWorkspace: { _, _, _ in },
        newWorkspace: { _ in },
        closeTerminal: { _ in },
        closeWorkspace: { _, _ in },
        renameWorkspace: { _, _ in },
        renameTerminal: { _, _ in },
        selectLocalWorkspace: { _ in },
        copyToPasteboard: { _ in },
        copyPortLink: { _ in },
        refresh: {}
    )
}
#endif
