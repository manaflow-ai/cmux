#if os(iOS)
import CmuxDeviceHub
import CmuxMobileDesign
public import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The Computer Use question as a sheet (HIG "Sheets": a scoped task the person
/// finishes or dismisses): who asks, on which machine, for which app, and the
/// answers that machine allows. Every Allow asks for Face ID before it is signed.
public struct ComputerUseApprovalSheet: View {
    let approvals: ComputerUseApprovals
    let sheet: ComputerUseApprovals.Sheet

    public init(approvals: ComputerUseApprovals, sheet: ComputerUseApprovals.Sheet) {
        self.approvals = approvals
        self.sheet = sheet
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(.horizontal, theme.metrics.sideMargin)
                .padding(.vertical, 16)
            }
            .background(theme.colors.sheet.color)
            .navigationTitle(Text("Computer Use"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { approvals.dismiss() } label: { Text(isFinished ? "Done" : "Later") }
                        .disabled(isDeciding)
                }
            }
        }
        .interactiveDismissDisabled(isDeciding)
    }

    private var isDeciding: Bool { decidingChoice != nil }

    private var decidingChoice: ComputerUseChoice? {
        if case let .deciding(choice) = sheet.phase { return choice }
        return nil
    }

    private var isFinished: Bool {
        switch sheet.phase {
        case .decided, .failed: true
        case .loading, .ready, .deciding: false
        }
    }

    @ViewBuilder private var content: some View {
        if let review = sheet.review {
            question(review)
        }
        switch sheet.phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking the request…").font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
        case .ready, .deciding:
            if let review = sheet.review { choices(review) }
        case let .decided(decision):
            Label(decidedText(decision), systemImage: decision == .deny ? "hand.raised" : "checkmark.circle")
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label)
                .accessibilityIdentifier("computerUse.decided")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label2)
                .accessibilityIdentifier("computerUse.failed")
        }
    }

    private func question(_ review: ComputerUseApprovalReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(review.agent) wants to use \(review.appName)")
                .font(theme.type.sheetTitle)
                .foregroundStyle(theme.colors.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("computerUse.title")
            VStack(alignment: .leading, spacing: 0) {
                row("On", review.machineName, symbol: "desktopcomputer")
                if let workspace = review.workspace { row("Workspace", workspace, symbol: "folder") }
                if let tool = review.tool { row("Action", tool, symbol: "cursorarrow.click") }
                row("App", review.appName, detail: review.appIdentifier, symbol: "app")
            }
            .background(theme.colors.surface.color, in: .rect(cornerRadius: 14))
            if let deadline = review.deadline {
                Text("You can answer until \(deadline, style: .time).")
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, detail: String? = nil, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(theme.type.rowSubtitle)
                .foregroundStyle(theme.colors.label2)
                .frame(width: theme.metrics.settingsIconFrame)
                .accessibilityHidden(true)
            Text(label).font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: value).font(theme.type.rowTitle).foregroundStyle(theme.colors.label).multilineTextAlignment(.trailing)
                if let detail {
                    Text(verbatim: detail).font(theme.type.meta).foregroundStyle(theme.colors.label2).lineLimit(2).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func choices(_ review: ComputerUseApprovalReview) -> some View {
        let deciding = decidingChoice
        return VStack(spacing: 10) {
            PrimaryCapsule("Allow Once", isLoading: deciding == .allowOnce) { approvals.choose(.allowOnce) }
                .accessibilityIdentifier("computerUse.allowOnce")
            SecondaryCapsule("Allow for This Session") { approvals.choose(.allowSession) }
                .accessibilityIdentifier("computerUse.allowSession")
            if review.offers(.alwaysAllow) {
                SecondaryCapsule("Always Allow \(review.appName)") { approvals.choose(.alwaysAllow) }
                    .accessibilityIdentifier("computerUse.alwaysAllow")
            }
            Button(role: .destructive) { approvals.choose(.deny) } label: {
                Text("Deny")
                    .font(theme.type.cta)
                    .foregroundStyle(theme.colors.dangerText)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("computerUse.deny")
            Text("Allow asks for Face ID.")
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
        }
        .disabled(deciding != nil)
        .padding(.top, 4)
    }

    private func decidedText(_ decision: ComputerUseDecision) -> LocalizedStringKey {
        switch decision {
        case .once: "Allowed once."
        case .session: "Allowed for this session."
        case .always: "Always allowed."
        case .deny: "Denied."
        }
    }
}
#endif
