import CmuxCloud
import CmuxCloudBannerCore
import CmuxSurfaceCatalogModel
import SwiftUI

/// The Cloud panel's tip slot: at most one quiet footer row, under the tree
/// where nothing else draws.
///
/// It reads the facts the panel already shows, hands them to
/// ``CloudHintsCenter``, and draws the queue's single current tip. The slot is
/// empty while the panel is loading or failing, while Get started is showing
/// (one teaching surface at a time), and while a header popover is open.
struct CloudHintsPanelSection: View {
    @ObservedObject var viewModel: MachinesPanelViewModel
    @ObservedObject private var secrets = CloudSecretsService.shared
    let dismissals: CloudBannerDismissalStore
    let presentation: CloudTeamPickerPresentation?
    var center: CloudHintsCenter = .shared
    var bridge: CloudGettingStartedSecretsBridge = .shared
    var now: () -> Date = { Date() }

    private var isGettingStartedVisible: Bool {
        !dismissals.isDismissed(
            id: CloudGettingStartedChecklist.dismissalID,
            signature: CloudGettingStartedChecklist.dismissalSignature
        )
    }

    private var isBlocked: Bool {
        !viewModel.hasLoadedOnce
            || viewModel.listStatus != nil
            || viewModel.treeErrorDescription != nil
            || isGettingStartedVisible
            || presentation?.isPresented == true
            || presentation?.isInvitePresented == true
            || presentation?.isHelpPresented == true
    }

    private var facts: CloudHintsCenter.Facts {
        CloudHintsPanelSection.facts(
            machines: viewModel.visibleMachines,
            catalog: viewModel.visibleCatalog,
            unreadFailureTerminalIDs: viewModel.unreadFailureTerminalIDs,
            secretNames: bridge.secretCount == nil ? nil : secrets.records.map(\.name)
        )
    }

    var body: some View {
        let hint = center.queue.current(isBlocked: isBlocked)
        let presentation = hint.flatMap(center.presentation(for:))
        VStack(spacing: 0) {
            if let presentation {
                CloudHintRow(
                    hint: presentation,
                    onPerform: {
                        center.queue.retire(presentation.id)
                        presentation.perform?()
                    },
                    onDismiss: { center.queue.retire(presentation.id) }
                )
                .id(presentation.id)
                .transition(.opacity)
                .onAppear { center.queue.noteDisplayed(presentation.id, at: now()) }
                .onDisappear { center.queue.noteDisplayEnded(at: now()) }
            }
        }
        .onChange(of: facts, initial: true) { _, facts in center.update(facts) }
    }

    /// Reduces the panel's state to the facts that earn a tip.
    /// - Parameters:
    ///   - machines: The machines the panel lists.
    ///   - catalog: The tree's catalog, for forwarded ports.
    ///   - unreadFailureTerminalIDs: Unread agent failures per machine.
    ///   - secretNames: Names in Cloud Secrets, or nil before the vault loads
    ///     (an unknown vault never earns the key tip).
    static func facts(
        machines: [MachineSnapshot],
        catalog: SurfaceCatalogSnapshot,
        unreadFailureTerminalIDs: [String: Set<String>],
        secretNames: [String]?
    ) -> CloudHintsCenter.Facts {
        var facts = CloudHintsCenter.Facts()
        if let machine = machines.first(where: { $0.activity == .ready && $0.freeAccess != .expired }) {
            facts.readyMachine = .init(id: machine.id, label: machine.displayName)
        }
        let labels = Dictionary(machines.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        for resource in CloudTreeNodeBuilder.portResources(catalog.resources) {
            guard case .cloud(let machineID) = resource.machine, let port = resource.port,
                  let label = labels[machineID] else { continue }
            facts.forwardedPort = .init(machineID: machineID, machineLabel: label, port: port)
            break
        }
        facts.hasUnreadAgentFailure = unreadFailureTerminalIDs.values.contains { !$0.isEmpty }
        if let secretNames {
            facts.hasAgentKey = secretNames.contains(where: Self.isAgentKey)
        } else {
            facts.hasAgentKey = true
        }
        return facts
    }

    /// An API key or login token a coding agent reads.
    static func isAgentKey(_ name: String) -> Bool {
        if name == "CLAUDE_CODE_OAUTH_TOKEN" { return true }
        return CloudSecretCatalog.presets.contains {
            $0.name == name && $0.credential == .apiKey && !$0.agents.isEmpty
        }
    }
}

/// One tip as a quiet footer row: no card and no border until hover, the whole
/// row runs the tip's action, and a close button appears on hover.
private struct CloudHintRow: View {
    let hint: CloudHintPresentation
    let onPerform: () -> Void
    let onDismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hint.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(hint.title)
                    .cmuxFont(size: 12, weight: .medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(hint.detail)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            CloudBannerDismissButton(action: onDismiss)
                .opacity(isHovered ? 1 : 0)
                .accessibilityLabel(String(localized: "cloudHints.dismiss", defaultValue: "Dismiss Tip"))
                .accessibilityIdentifier("CloudHintDismissButton")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered && hint.perform != nil ? 0.05 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { if hint.perform != nil { onPerform() } }
        .onHover { isHovered = $0 }
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding - 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hint.perform != nil ? .isButton : [])
        .accessibilityAction(named: Text(String(localized: "cloudHints.dismiss", defaultValue: "Dismiss Tip")), onDismiss)
        .accessibilityIdentifier("CloudHintRow.\(hint.id)")
    }
}
