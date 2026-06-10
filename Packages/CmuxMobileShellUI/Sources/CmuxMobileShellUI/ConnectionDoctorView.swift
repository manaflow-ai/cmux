import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The connection doctor screen: one environment-probed checkup of the
/// phone-to-Mac connection, rendered as a decision-tree-ordered checklist
/// (network, tailnet, account, Mac app, listener, routes) where every row is
/// pass, fail-with-a-fix, honestly unknown, or skipped, and the first failing
/// row is marked as the place to start.
///
/// Entrances today: the pairing-failure sheet and the disconnected screen
/// (both wired through ``CMUXMobileRootView``). The setup-help surface from
/// https://github.com/manaflow-ai/cmux/pull/5714 mounts this same view once
/// both branches land; its whole contract is the `makeDoctor` factory.
struct ConnectionDoctorView: View {
    /// Builds the doctor for this presentation; called once on first run.
    let makeDoctor: @MainActor () -> ConnectionDoctor
    let done: () -> Void

    /// Identity of the current probe run plus why it started. Changing the
    /// value restarts `.task(id:)`, which structurally cancels the superseded
    /// run; the doctor's own generation guard additionally drops any stale
    /// results that were already in flight.
    private struct RunRequest: Equatable {
        var generation = 0
        var trigger = "appear"

        mutating func rerun(trigger: String) {
            generation += 1
            self.trigger = trigger
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var doctor: ConnectionDoctor?
    @State private var runRequest = RunRequest()

    var body: some View {
        NavigationStack {
            checklist
                .navigationTitle(L10n.string("mobile.doctor.title", defaultValue: "Connection Checkup"))
                .mobileInlineNavigationTitle()
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .confirmationAction) {
                        doneButton
                    }
                    #else
                    ToolbarItem {
                        doneButton
                    }
                    #endif
                }
        }
        .task(id: runRequest) {
            let doctor = resolvedDoctor()
            await doctor.run(trigger: runRequest.trigger)
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground is exactly when the environment
            // changed (the user flipped Tailscale on, granted Local Network,
            // woke the Mac), so re-probe automatically.
            guard phase == .active else { return }
            runRequest.rerun(trigger: "foreground")
        }
        .accessibilityIdentifier("MobileConnectionDoctorView")
    }

    @ViewBuilder private var checklist: some View {
        List {
            if let report = doctor?.report {
                Section {
                    ForEach(report.items) { item in
                        ConnectionDoctorRowView(
                            item: item,
                            isPrimaryFailure: item.id == report.primaryFailure?.id
                        )
                    }
                } footer: {
                    Text(summaryText(for: report))
                        .accessibilityIdentifier("MobileConnectionDoctorSummary")
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("mobile.doctor.running", defaultValue: "Checking your setup…"))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("MobileConnectionDoctorRunning")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            runAgainButton
        }
    }

    private var doneButton: some View {
        Button(action: done) {
            Text(L10n.string("mobile.common.done", defaultValue: "Done"))
        }
        .accessibilityIdentifier("MobileConnectionDoctorDoneButton")
    }

    private var runAgainButton: some View {
        Button {
            runRequest.rerun(trigger: "rerun")
        } label: {
            HStack {
                Spacer(minLength: 0)
                Text(L10n.string("mobile.doctor.runAgain", defaultValue: "Run Again"))
                    .mobileButtonLoading(doctor?.isRunning != false, tint: .white)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.blue)
        .disabled(doctor?.isRunning != false)
        .accessibilityIdentifier("MobileConnectionDoctorRunAgainButton")
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 12)
        .background {
            PlatformPalette.systemBackground
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Returns the presentation's doctor, building it on the first run.
    private func resolvedDoctor() -> ConnectionDoctor {
        if let doctor {
            return doctor
        }
        let doctor = makeDoctor()
        self.doctor = doctor
        return doctor
    }

    private func summaryText(for report: ConnectionDoctorReport) -> String {
        if report.primaryFailure != nil {
            return L10n.string(
                "mobile.doctor.summary.fixFirst",
                defaultValue: "Fix the highlighted item first, then run the checkup again."
            )
        }
        return L10n.string(
            "mobile.doctor.summary.healthy",
            defaultValue: "Everything checks out. If you still can't connect, quit and reopen cmux on the Mac, then try again."
        )
    }
}

/// One checklist row: a status icon, the check's title, the one-line fix,
/// detail, or note, and a "Start here" badge on the first failing row.
private struct ConnectionDoctorRowView: View {
    let item: ConnectionDoctorItem
    let isPrimaryFailure: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title)
                    if isPrimaryFailure {
                        startHereBadge
                    }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(item.isFailure ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileConnectionDoctorRow_\(item.id.rawValue)")
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
        }
    }

    private var startHereBadge: some View {
        Text(L10n.string("mobile.doctor.startHere", defaultValue: "Start here"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red.opacity(0.15), in: Capsule())
            .foregroundStyle(.red)
    }

    private var message: String? {
        switch item.status {
        case let .pass(detail):
            return detail
        case let .fail(fix):
            return fix
        case let .unknown(note):
            return note
        case let .skipped(note):
            return note
        }
    }
}
