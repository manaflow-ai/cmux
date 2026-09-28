import AppKit
import CMUXAgentLaunch
import SwiftUI

/// The user's answer to a batch permission request.
enum AgentPermissionGrantDecision: Sendable, Equatable {
    case approved(Set<String>)
    case denied
}

/// A floating approval panel for one `permissions.request`.
///
/// The panel is non-activating: it appears above other windows without
/// activating cmux or moving keyboard focus until the user clicks it.
/// Closing the panel, pressing Escape, or the request timing out all deny.
/// Approving takes a mouse click on the Approve button: it has no keyboard
/// shortcut, can't take focus, ignores accessibility press actions, and
/// stays disabled for a moment after the panel appears so a click aimed at
/// something else can't land on it.
@MainActor
final class AgentPermissionGrantApprovalPanel: NSObject, NSWindowDelegate {
    /// Panels stay alive while they wait for an answer.
    private static var pending: [ObjectIdentifier: AgentPermissionGrantApprovalPanel] = [:]

    private let proposal: AgentPermissionGrantProposal
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<AgentPermissionGrantDecision, Never>?
    private var decision: AgentPermissionGrantDecision?

    private init(proposal: AgentPermissionGrantProposal) {
        self.proposal = proposal
    }

    /// Shows the panel and waits for the user. Cancelling the calling task
    /// closes the panel and denies.
    nonisolated static func requestDecision(
        for proposal: AgentPermissionGrantProposal
    ) async -> AgentPermissionGrantDecision {
        let controller = await MainActor.run { AgentPermissionGrantApprovalPanel(proposal: proposal) }
        return await withTaskCancellationHandler {
            await controller.run()
        } onCancel: {
            Task { @MainActor in controller.finish(.denied) }
        }
    }

    private func run() async -> AgentPermissionGrantDecision {
        if let decision { return decision }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        let view = AgentPermissionGrantApprovalView(
            proposal: proposal,
            requester: Self.requesterDescription(for: proposal),
            approve: { [weak self] selected in self?.finish(.approved(selected)) },
            deny: { [weak self] in self?.finish(.denied) }
        )
        let hosting = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.agentPermissions.approval")
        panel.title = String(
            localized: "agentPermissions.approval.windowTitle",
            defaultValue: "Agent Permission Request"
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 460, height: 320)
        panel.delegate = self
        panel.center()
        self.panel = panel
        Self.pending[ObjectIdentifier(self)] = self
        panel.orderFrontRegardless()
    }

    fileprivate func finish(_ decision: AgentPermissionGrantDecision) {
        guard self.decision == nil else { return }
        self.decision = decision
        continuation?.resume(returning: decision)
        continuation = nil
        let panel = self.panel
        self.panel = nil
        panel?.delegate = nil
        panel?.close()
        Self.pending.removeValue(forKey: ObjectIdentifier(self))
    }

    func windowWillClose(_ notification: Notification) {
        finish(.denied)
    }

    /// The workspace and tab the request says it came from, by name, when
    /// they exist.
    private static func requesterDescription(for proposal: AgentPermissionGrantProposal) -> String? {
        guard let workspaceID = proposal.workspaceID,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceID) else { return nil }
        let workspaceName = workspace.customTitle ?? workspace.title
        guard let surfaceID = proposal.surfaceID,
              let surfaceName = workspace.panelTitle(panelId: surfaceID) else { return workspaceName }
        return String(
            format: String(
                localized: "agentPermissions.approval.requesterWorkspaceTab",
                defaultValue: "%1$@, tab %2$@"
            ),
            workspaceName,
            surfaceName
        )
    }
}

private struct AgentPermissionGrantApprovalView: View {
    /// How long Approve stays disabled after the panel appears.
    private static let armingDelayNanoseconds: UInt64 = 1_000_000_000

    let proposal: AgentPermissionGrantProposal
    let requester: String?
    let approve: @MainActor (Set<String>) -> Void
    let deny: @MainActor () -> Void
    @State private var selected: Set<String>
    @State private var isArmed = false

    init(
        proposal: AgentPermissionGrantProposal,
        requester: String?,
        approve: @escaping @MainActor (Set<String>) -> Void,
        deny: @escaping @MainActor () -> Void
    ) {
        self.proposal = proposal
        self.requester = requester
        self.approve = approve
        self.deny = deny
        _selected = State(initialValue: proposal.defaultSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                String(localized: "agentPermissions.approval.heading",
                       defaultValue: "An agent is asking for these permissions"),
                systemImage: "checkmark.shield"
            )
            .font(.title3.weight(.semibold))

            if let reason = proposal.reason {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "agentPermissions.approval.reasonLabel",
                                defaultValue: "The agent says:"))
                        .foregroundStyle(.secondary)
                    // Untrusted text from the agent, shown as a quote only.
                    Text(verbatim: "\u{201C}\(reason)\u{201D}")
                        .italic()
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(proposal.rules) { rule in
                        ruleRow(rule)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(String(localized: "agentPermissions.approval.scopeLabel", defaultValue: "Applies to"))
                        .foregroundStyle(.secondary)
                    Text(scopeText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if let requester {
                    GridRow {
                        Text(String(localized: "agentPermissions.approval.requesterLabel",
                                    defaultValue: "Requested from"))
                            .foregroundStyle(.secondary)
                        Text(verbatim: requester)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                GridRow {
                    Text(String(localized: "agentPermissions.approval.expiresLabel", defaultValue: "Expires"))
                        .foregroundStyle(.secondary)
                    Text(Date().addingTimeInterval(proposal.expiresIn).formatted(date: .abbreviated, time: .shortened))
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "agentPermissions.approval.deny", defaultValue: "Deny")) {
                    deny()
                }
                .keyboardShortcut(.cancelAction)
                MouseClickOnlyButton(
                    title: String(localized: "agentPermissions.approval.approveSelected",
                                  defaultValue: "Approve Selected"),
                    isEnabled: isArmed && !selected.isEmpty
                ) {
                    approve(selected)
                }
                .fixedSize()
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
        .task {
            try? await Task.sleep(nanoseconds: Self.armingDelayNanoseconds)
            isArmed = true
        }
    }

    private var scopeText: String {
        switch proposal.scope {
        case .session(let id):
            return String(format: String(localized: "agentPermissions.approval.scopeSession",
                                         defaultValue: "This agent session (%@)"), id)
        case .project(let root):
            return String(format: String(localized: "agentPermissions.approval.scopeProject",
                                         defaultValue: "Every agent session in %@"), root)
        }
    }

    private func ruleRow(_ rule: AgentPermissionGrantProposal.Rule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { selected.contains(rule.rule) },
                set: { isOn in
                    if isOn { selected.insert(rule.rule) } else { selected.remove(rule.rule) }
                }
            )) {
                Text(verbatim: rule.rule)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .toggleStyle(.checkbox)
            if rule.isBroad {
                Label(
                    String(localized: "agentPermissions.approval.broadWarning",
                           defaultValue: "Broad: covers any command, file, or host of this kind."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 20)
            }
        }
    }
}

/// A push button only a mouse click can press: no key equivalent, never
/// first responder, and accessibility press actions are refused. The action
/// also checks that a left mouse-up in this button's window is the event
/// being handled.
private struct MouseClickOnlyButton: NSViewRepresentable {
    let title: String
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = ClickOnlyNSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction(_:))
        )
        button.bezelStyle = .push
        button.keyEquivalent = ""
        button.refusesFirstResponder = true
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func performAction(_ sender: NSButton) {
            guard let event = NSApp.currentEvent,
                  event.type == .leftMouseUp,
                  event.window === sender.window else { return }
            action()
        }
    }

    private final class ClickOnlyNSButton: NSButton {
        override var acceptsFirstResponder: Bool { false }

        override func accessibilityPerformPress() -> Bool { false }
    }
}
