import CmuxCloud
import SwiftUI

/// The Cloud Secrets sheet's Agents section for one machine: a status chip per
/// agent CLI (installed, credential, endpoint), "Checked just now", and Check
/// Now, which also asks each key's own provider whether it accepts the key.
/// Each problem gets one line with its fix and, when the fix is a key, a button
/// that opens the sheet's add card for that name. Same rows as `cmux vm doctor`.
struct CloudAgentReadinessSection: View {
    let sheet: CloudSecretsSheetModel
    @State private var readiness: CloudAgentReadinessModel

    init(sheet: CloudSecretsSheetModel, machineID: String) {
        self.sheet = sheet
        _readiness = State(initialValue: CloudAgentReadinessModel(
            machineID: machineID,
            machineLabel: sheet.machineLabel,
            service: .live
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CloudAgentReadiness")
        .task { readiness.checkIfNeeded() }
        .onDisappear { readiness.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "cloudAgentReadiness.ui.title", defaultValue: "Agents"))
                .cmuxFont(size: 12, weight: .medium)
            Spacer(minLength: 8)
            if readiness.isChecking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(String(localized: "cloudAgentReadiness.ui.checking", defaultValue: "Checking agents"))
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let label = readiness.checkedLabel(now: context.date) {
                        Text(label)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Button(String(localized: "cloudAgentReadiness.ui.checkNow", defaultValue: "Check Now")) {
                readiness.check(probe: true)
            }
            .disabled(readiness.isChecking)
            .help(String(
                localized: "cloudAgentReadiness.ui.checkNow.help",
                defaultValue: "Check each agent on this machine and ask each key's own provider whether it accepts the key. Keys go only to their provider, never to cmux."
            ))
            .accessibilityIdentifier("CloudAgentReadiness.check")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch readiness.phase {
        case .idle:
            checkingBody
        case .checking where readiness.assessments.isEmpty:
            checkingBody
        case .unavailable:
            Text(String(localized: "cloudAgentReadiness.ui.unavailable", defaultValue: "This machine could not report its agents. Wake it and check again."))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            CloudSecretsMessageBox(text: message, isError: true)
        case .checking, .loaded:
            chips
            ForEach(readiness.issues, id: \.entry.agent) { assessment in
                issueRow(assessment)
            }
        }
    }

    private var checkingBody: some View {
        Text(String(localized: "cloudAgentReadiness.ui.checkingBody", defaultValue: "Checking which agents can start on this machine\u{2026}"))
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
    }

    private var chips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(readiness.assessments, id: \.entry.agent) { assessment in
                CloudAgentReadinessChip(assessment: assessment)
            }
        }
    }

    private func issueRow(_ assessment: CloudAgentReadinessAssessment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: assessment.status == .problem ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .foregroundStyle(CloudAgentReadinessChip.tint(assessment.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.issueText(assessment))
                    .cmuxFont(size: 11)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = assessment.fix {
                    Text(fix)
                        .cmuxFont(size: 11, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let key = CloudAgentReadinessModel.keyToSet(for: assessment) {
                Button(String(format: String(localized: "cloudAgentReadiness.ui.setKey", defaultValue: "Set %@\u{2026}"), key)) {
                    sheet.beginAdd(name: key)
                }
                .controlSize(.small)
                .disabled(!sheet.canAdd || sheet.hasModalCard)
                .accessibilityIdentifier("CloudAgentReadiness.set.\(assessment.entry.agent.rawValue)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func issueText(_ assessment: CloudAgentReadinessAssessment) -> String {
        String(
            format: String(localized: "cloudAgentReadiness.ui.issue", defaultValue: "%1$@: %2$@"),
            CloudAgentReadinessAssessment.displayName(assessment.entry.agent), assessment.detail
        )
    }
}

/// One agent: a status dot and its name; the tooltip carries credential,
/// endpoint, and why.
private struct CloudAgentReadinessChip: View {
    let assessment: CloudAgentReadinessAssessment

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.tint(assessment.status))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(CloudAgentReadinessAssessment.displayName(assessment.entry.agent))
                .cmuxFont(size: 11, weight: .medium)
                .lineLimit(1)
            Text(assessment.statusLabel)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Self.tint(assessment.status).opacity(0.1)))
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(tooltip)
        .accessibilityIdentifier("CloudAgentReadiness.chip.\(assessment.entry.agent.rawValue)")
    }

    private var accessibilityName: String {
        String(
            format: String(localized: "cloudAgentReadiness.ui.chip.accessibility", defaultValue: "%1$@: %2$@"),
            CloudAgentReadinessAssessment.displayName(assessment.entry.agent), assessment.statusLabel
        )
    }

    private var tooltip: String {
        var parts = [
            String(format: String(localized: "cloudAgentReadiness.ui.credential", defaultValue: "Credential: %@"), assessment.credential),
            String(format: String(localized: "cloudAgentReadiness.ui.endpoint", defaultValue: "Sends to: %@"), assessment.endpoint),
            assessment.detail,
        ]
        if let version = assessment.entry.version {
            parts.insert(String(format: String(localized: "cloudAgentReadiness.ui.version", defaultValue: "Version %@"), version), at: 0)
        }
        return parts.joined(separator: "\n")
    }

    static func tint(_ status: CloudAgentReadinessAssessment.Status) -> Color {
        switch status {
        case .ready: return .green
        case .attention: return .orange
        case .problem: return .red
        case .unknown: return .secondary
        }
    }
}
