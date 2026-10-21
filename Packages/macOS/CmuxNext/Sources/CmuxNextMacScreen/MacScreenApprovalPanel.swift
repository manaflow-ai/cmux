import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups
public import Observation
import SwiftUI

/// The host's approval prompt for a device hub request (permission Ask):
/// the viewer device's name and key fingerprint and the scope it asks for,
/// with Deny, Allow Once, Always Allow View Only and Always Allow Full
/// Control. A floating, non-activating panel at the top right of the main
/// screen: it shows over every app (full-screen ones too) and never takes
/// the keyboard or the frontmost app from the person. One request at a
/// time, in arrival order; a request the hub ends (revoked, timed out)
/// leaves the panel, and the panel gives up after the protocol's five
/// minutes on its own.
@MainActor @Observable
public final class MacScreenApprovalPrompt {
    /// The request on screen.
    public private(set) var current: SessionRequest?
    /// The last answer failed (the request ended meanwhile, the network).
    public private(set) var error: String?
    public private(set) var answering = false
    /// How long a request may wait (PROTOCOL.md: requests expire after 5 min).
    @ObservationIgnored var lifetime: Duration = .seconds(300)
    @ObservationIgnored var hub: @MainActor () -> DeviceHub? = { nil }
    /// Requests answered or expired here, which the hub may still list for a moment.
    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private let expiry = DemandTimer(owner: "mac-screen.approval-expiry")
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Shows and hides the panel; tests replace it.
    @ObservationIgnored var present: @MainActor (Bool) -> Void = { _ in }

    public init() {
        present = { [weak self] visible in self?.setPanelVisible(visible) }
    }

    /// Follows `hub`'s pending requests from now on (nil: none).
    func follow(_ hub: DeviceHub?) {
        watch?.cancel()
        watch = nil
        settled = []
        update(hub?.pendingRequests ?? [])
        guard let hub else { return }
        watch = Task { [weak self] in
            for await requests in ObservationStream({ hub.pendingRequests }) {
                guard !Task.isCancelled else { return }
                self?.update(requests)
            }
        }
    }

    /// The hub's pending requests changed: show the oldest unanswered one.
    func update(_ requests: [SessionRequest]) {
        let open = requests.filter { !settled.contains($0.id) }
        let next = open.first { $0.id == current?.id } ?? open.first
        guard next?.id != current?.id else { return }
        current = next
        error = nil
        answering = false
        expiry.cancel()
        if let next {
            expiry.schedule(after: lifetime) { @MainActor [weak self] in
                guard let self, current?.id == next.id else { return }
                settled.insert(next.id)
                update(self.hub()?.pendingRequests ?? [])
            }
        }
        present(next != nil)
    }

    /// One of the prompt's buttons.
    public func answer(_ choice: MacScreenApprovalChoice) {
        guard let request = current, let hub = hub(), !answering else { return }
        answering = true
        let (decision, scope, thenPermission) = choice.answer(requested: request.scope)
        // task-owner: one decision for the request on screen; the next request shows when it settles
        Task { [weak self] in
            do {
                try await hub.decide(request, decision: decision, scope: scope)
                if let thenPermission {
                    try await hub.setPermission(host: hub.identity.id, viewer: request.viewerId, scope: thenPermission)
                }
                self?.settle(request.id, hub: hub)
            } catch let failure as DeviceHubError where failure.code == .sessionNotPending || failure.code == .notFound {
                // It ended meanwhile (cancelled by the viewer, expired): nothing to answer.
                self?.settle(request.id, hub: hub)
            } catch {
                guard let self else { return }
                answering = false
                self.error = L.t("macScreen.approval.failed", "The answer did not reach the device hub. Try again.")
            }
        }
    }

    private func settle(_ id: String, hub: DeviceHub) {
        settled.insert(id)
        current = nil
        update(hub.pendingRequests)
    }

    // MARK: Panel

    /// Where the prompt's panel shows; nil while hidden (tests).
    var panelFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    private func setPanelVisible(_ visible: Bool) {
        guard visible, current != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh content view per request, laid out before it is measured: a
        // reused hosting view still draws the last state (nothing, between
        // requests) when it is read, which gave a 0×0 panel from the second prompt on.
        let content = MacScreenHostingView(MacScreenApprovalView(prompt: self))
        content.sizingOptions = []
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        if size.width < 300 || size.height < 100 { size = CGSize(width: max(size.width, 380), height: max(size.height, 220)) }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: size.width + 32, height: size.height + 32)
        panel.setFrame(CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height),
                       display: true)
        // Over every app, without activating this one or taking the keyboard.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// The prompt's content, in the app theme.
struct MacScreenApprovalView: View {
    let prompt: MacScreenApprovalPrompt
    @Environment(\.macScreenColors) private var colors

    var body: some View {
        if let request = prompt.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: request.scope == .full ? "cursorarrow.and.square.on.square.dashed" : "eye")
                        .font(MacScreenType.glyph).foregroundStyle(colors.accent)
                    Text(String(format: request.scope == .full
                            ? L.t("macScreen.approval.titleFull", "%@ wants to control this Mac")
                            : L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), request.viewerName))
                        .font(MacScreenType.emphasized)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(format: L.t("macScreen.approval.scope", "Asks for %@."), request.scope.title))
                    .foregroundStyle(colors.secondary)
                if let fingerprint = request.viewerKeyFingerprint {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("macScreen.approval.fingerprint", "Device key fingerprint")).font(MacScreenType.caption)
                            .foregroundStyle(colors.secondary)
                        Text(DeviceIdentity.displayFingerprint(fingerprint)).font(MacScreenType.code).textSelection(.enabled)
                    }
                }
                if let error = prompt.error {
                    Text(error).font(MacScreenType.caption).foregroundStyle(colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button(MacScreenApprovalChoice.deny.title) { prompt.answer(.deny) }
                        .buttonStyle(MacScreenButtonStyle(role: .destructive))
                        .accessibilityIdentifier("macScreen.approval.deny")
                    Spacer(minLength: 8)
                    Button(MacScreenApprovalChoice.once.title) { prompt.answer(.once) }
                        .buttonStyle(MacScreenButtonStyle(role: .primary))
                        .accessibilityIdentifier("macScreen.approval.once")
                }
                HStack(spacing: 8) {
                    Button(MacScreenApprovalChoice.alwaysView.title) { prompt.answer(.alwaysView) }
                        .buttonStyle(MacScreenButtonStyle(compact: true))
                        .accessibilityIdentifier("macScreen.approval.alwaysView")
                    Button(MacScreenApprovalChoice.alwaysFull.title) { prompt.answer(.alwaysFull) }
                        .buttonStyle(MacScreenButtonStyle(compact: true))
                        .accessibilityIdentifier("macScreen.approval.alwaysFull")
                }
            }
            .disabled(prompt.answering)
            .font(MacScreenType.body)
            .foregroundStyle(colors.primary)
            .padding(16)
            .frame(width: 380, alignment: .leading)
            .background(colors.popup, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous))
            .overlay {
                if colors.borders {
                    RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous).strokeBorder(colors.separator)
                }
            }
            .accessibilityIdentifier("macScreen.approval")
        }
    }
}
